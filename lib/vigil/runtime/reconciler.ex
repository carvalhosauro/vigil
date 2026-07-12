defmodule Vigil.Runtime.Reconciler do
  @moduledoc """
  Owns the actual running `%Config{}` and reconciles it toward a desired state
  loaded from a configuration directory (RFC-0006).

  This is the single reconciliation path (DEC-006): a future filesystem
  watcher and the manual `vigil reload` CLI both call `reconcile/0`
  (RFC-0006 §15) — there is no other way to mutate the running Runtime
  topology.

  Flow: load → validate → diff → apply (RFC-0006 §5).

    * load/validate failure ⇒ reject, current config untouched, `reload.rejected`.
    * success ⇒ diff the resolved desired config against the current
      (actual) one, apply per-resource, `reload.completed` carrying the diff
      and applied-work summary (DEC-007).

  Applying is best-effort per asset (a single `start_child`/`update_config`
  failure does not abort the rest of the reload) — the all-or-nothing
  guarantee (RFC-0006 §9, DEC-002/003) lives entirely in the validation gate:
  a config that fails `Config.validate/1` never reaches apply.

  Boot (`init/1`) runs the exact same apply step against an empty actual
  config, so every Asset is an `added` entry and gets a worker the same way a
  reload would start one — one mechanism for both.
  """

  use GenServer

  alias Vigil.Adapters.ConfigLoader
  alias Vigil.Core.{Config, ConfigDiff}
  alias Vigil.Runtime.{AssetWorker, Events, WorkersSupervisor}

  @registry Vigil.Runtime.WorkerRegistry
  @cycle_task_supervisor Vigil.Runtime.CycleTaskSupervisor
  @dispatch_task_supervisor Vigil.Runtime.DispatchTaskSupervisor
  @empty_config %Config{assets: %{}, rules: %{}, notifiers: %{}, defaults: nil}

  @type applied :: %{
          started: [String.t()],
          stopped: [String.t()],
          restarted: [String.t()],
          updated: [String.t()],
          unchanged: [String.t()],
          failed: [{String.t(), atom(), term()}]
        }

  @type summary :: %{diff: ConfigDiff.t(), applied: applied()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Reloads from the held configuration directory (RFC-0006 §15).
  """
  @spec reconcile() :: {:ok, summary()} | {:error, term()}
  def reconcile, do: GenServer.call(__MODULE__, :reconcile, :infinity)

  @doc """
  Reloads from the given configuration directory. Does not change the
  directory used by a subsequent `reconcile/0`.
  """
  @spec reconcile(String.t()) :: {:ok, summary()} | {:error, term()}
  def reconcile(config_dir) when is_binary(config_dir),
    do: GenServer.call(__MODULE__, {:reconcile, config_dir}, :infinity)

  @impl GenServer
  def init(opts) do
    config_dir = Keyword.get(opts, :config_dir, ConfigLoader.config_dir())
    config = Keyword.fetch!(opts, :config)

    # Initial sync: every configured Asset is `added` against an empty actual
    # config, so it starts a worker through the same apply path a reload uses.
    diff = ConfigDiff.diff(config, @empty_config)
    _applied = apply_diff(diff, config, @empty_config)

    {:ok, %{config_dir: config_dir, config: config}}
  end

  @impl GenServer
  def handle_call(:reconcile, _from, state), do: do_reload(state.config_dir, state)
  def handle_call({:reconcile, config_dir}, _from, state), do: do_reload(config_dir, state)

  @spec do_reload(String.t(), map()) ::
          {:reply, {:ok, summary()} | {:error, term()}, map()}
  defp do_reload(config_dir, state) do
    Events.emit([:reload, :started], %{}, %{config_dir: config_dir})

    case ConfigLoader.load(config_dir) do
      {:ok, desired} ->
        diff = ConfigDiff.diff(desired, state.config)
        applied = apply_diff(diff, desired, state.config)
        summary = %{diff: diff, applied: applied}

        Events.emit([:reload, :completed], %{}, %{diff: diff, applied: applied})
        {:reply, {:ok, summary}, %{state | config: desired}}

      {:error, reason} ->
        Events.emit([:reload, :rejected], %{}, %{reason: reason})
        {:reply, {:error, reason}, state}
    end
  end

  @spec apply_diff(ConfigDiff.t(), Config.t(), Config.t()) :: applied()
  defp apply_diff(diff, desired, actual) do
    {started, start_failed} = apply_each(diff.assets.added, :start, &start_worker(desired, &1))
    {stopped, stop_failed} = apply_each(diff.assets.removed, :stop, &stop_worker/1)

    {restarted, restart_failed} =
      apply_each(diff.assets.changed, :restart, &restart_worker(desired, &1))

    {updated, unchanged, update_failed} = apply_unchanged_assets(diff, desired, actual)

    %{
      started: started,
      stopped: stopped,
      restarted: restarted,
      updated: updated,
      unchanged: unchanged,
      failed: start_failed ++ stop_failed ++ restart_failed ++ update_failed
    }
  end

  # Common assets (present in both desired and actual) whose own Asset spec
  # did NOT change: either an in-place rule/notifier update, or untouched.
  @spec apply_unchanged_assets(ConfigDiff.t(), Config.t(), Config.t()) ::
          {[String.t()], [String.t()], [{String.t(), atom(), term()}]}
  defp apply_unchanged_assets(diff, desired, actual) do
    Enum.reduce(diff.assets.unchanged, {[], [], []}, fn name, {updated, unchanged, failed} ->
      if rules_or_notifiers_changed?(desired, actual, name) do
        case update_worker(desired, name) do
          :ok -> {[name | updated], unchanged, failed}
          {:error, reason} -> {updated, unchanged, [{name, :update, reason} | failed]}
        end
      else
        {updated, [name | unchanged], failed}
      end
    end)
    |> then(fn {updated, unchanged, failed} ->
      {Enum.reverse(updated), Enum.reverse(unchanged), Enum.reverse(failed)}
    end)
  end

  @spec apply_each([String.t()], atom(), (String.t() -> :ok | {:error, term()})) ::
          {[String.t()], [{String.t(), atom(), term()}]}
  defp apply_each(names, action, fun) do
    Enum.reduce(names, {[], []}, fn name, {ok, failed} ->
      case fun.(name) do
        :ok -> {[name | ok], failed}
        {:error, reason} -> {ok, [{name, action, reason} | failed]}
      end
    end)
    |> then(fn {ok, failed} -> {Enum.reverse(ok), Enum.reverse(failed)} end)
  end

  @spec rules_or_notifiers_changed?(Config.t(), Config.t(), String.t()) :: boolean()
  defp rules_or_notifiers_changed?(desired, actual, name) do
    desired.notifiers != actual.notifiers or rules_for(desired, name) != rules_for(actual, name)
  end

  @spec rules_for(Config.t(), String.t()) :: [Vigil.Core.Config.Rule.t()]
  defp rules_for(config, asset_name) do
    config.rules
    |> Map.values()
    |> Enum.filter(&(&1.asset == asset_name))
    |> Enum.sort_by(& &1.name)
  end

  @spec start_worker(Config.t(), String.t()) :: :ok | {:error, term()}
  defp start_worker(desired, name) do
    asset = Map.fetch!(desired.assets, name)

    case DynamicSupervisor.start_child(WorkersSupervisor, worker_child_spec(asset, desired)) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @spec stop_worker(String.t()) :: :ok | {:error, term()}
  defp stop_worker(name) do
    case worker_pid(name) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(WorkersSupervisor, pid)
      :error -> :ok
    end
  rescue
    error -> {:error, error}
  end

  @spec restart_worker(Config.t(), String.t()) :: :ok | {:error, term()}
  defp restart_worker(desired, name) do
    with :ok <- stop_worker(name) do
      start_worker(desired, name)
    end
  end

  @spec update_worker(Config.t(), String.t()) :: :ok | {:error, term()}
  defp update_worker(desired, name) do
    case worker_pid(name) do
      {:ok, pid} ->
        AssetWorker.update_config(pid,
          rules: rules_for(desired, name),
          channel_configs: desired.notifiers
        )

      :error ->
        {:error, :worker_not_found}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec worker_child_spec(Config.Asset.t(), Config.t()) :: {module(), keyword()}
  defp worker_child_spec(asset, config) do
    {AssetWorker,
     asset: asset,
     rules: rules_for(config, asset.name),
     channel_configs: config.notifiers,
     cycle_task_supervisor: @cycle_task_supervisor,
     dispatch_task_supervisor: @dispatch_task_supervisor,
     name: via(asset.name)}
  end

  @spec worker_pid(String.t()) :: {:ok, pid()} | :error
  defp worker_pid(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  defp via(name), do: {:via, Registry, {@registry, name}}
end
