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

  Boot (`init/1`) loads the desired config from disk and diffs it against
  `actual_from_runtime/0` — the actual state reconstructed from whatever
  `AssetWorker`s are currently alive under `WorkersSupervisor`, not always an
  empty config (see that function's doc). Loading from disk (rather than a
  config captured at boot) means a restart re-syncs to the current on-disk
  source of truth (DEC-001) instead of reverting to boot state.

  Two restart shapes reach `init/1`:

    * a true cold boot, or a `WorkersSupervisor` crash-restart (it is earlier
      in the `:rest_for_one` tree, so its crash takes every `AssetWorker`
      down with it) — `actual_from_runtime/0` sees no live workers, so every
      Asset in the desired config is `added` and gets a worker, exactly as
      before.
    * a Reconciler-only crash-restart — `WorkersSupervisor` and its
      `AssetWorker`s are earlier in the tree and survive — `actual_from_runtime/0`
      reconstructs their asset/rule/notifier state, so surviving assets diff
      as `unchanged`/`changed`/`removed` against the freshly reloaded desired
      config instead of every asset colliding with its own still-registered
      `:via` name as `added`. That collision (`{:error, {:already_started,
      pid}}`) is a real failure (RFC-0006: best-effort apply reports it, does
      not paper over it) — diffing against what is actually running avoids
      causing it in the first place, and also means an asset genuinely
      removed from disk while the Reconciler was down is now correctly
      stopped on restart, instead of its worker running forever unnoticed.
  """

  use GenServer

  require Logger

  alias Vigil.Adapters.ConfigLoader
  alias Vigil.Core.{Config, ConfigDiff}
  alias Vigil.Runtime.{AssetWorker, Events, WorkersSupervisor}

  @registry Vigil.Runtime.WorkerRegistry
  @cycle_task_supervisor Vigil.Runtime.CycleTaskSupervisor
  @dispatch_task_supervisor Vigil.Runtime.DispatchTaskSupervisor
  @empty_config %Config{assets: %{}, rules: %{}, notifiers: %{}, defaults: nil}

  # Bounds `await_deregistered/1` (see `restart_worker/2`): `Registry`
  # unregisters a terminated process's `:via` name asynchronously (its own
  # monitor firing on the process's `:DOWN`), so there is a gap after
  # `DynamicSupervisor.terminate_child/2` returns during which the name is
  # still taken. 1s is generous for a local monitor `:DOWN` to land; the poll
  # interval is short so the common case (already clear) barely adds latency.
  @deregister_timeout_ms 1_000
  @deregister_poll_interval_ms 10

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
    config = load_or_empty(config_dir)
    actual = actual_from_runtime()

    # Initial sync: diff desired against whatever is *actually* running right
    # now (see moduledoc and `actual_from_runtime/0`) — a cold boot or a
    # WorkersSupervisor-crash-restart naturally sees no live workers, so this
    # degrades to the same "everything added" sync as before.
    diff = ConfigDiff.diff(config, actual)
    _applied = apply_diff(diff, config, actual)

    {:ok, %{config_dir: config_dir, config: config}}
  end

  # Boot already fail-fast validated the config (Runtime.Supervisor), so a load
  # failure here is only reachable on a restart where the on-disk config has
  # since become invalid. Come up empty and let the next reconcile heal rather
  # than crash-loop the whole Runtime tree.
  @spec load_or_empty(String.t()) :: Config.t()
  defp load_or_empty(config_dir) do
    case ConfigLoader.load(config_dir) do
      {:ok, config} ->
        config

      {:error, reason} ->
        Logger.warning(
          "reconciler: config load failed on init, starting empty: #{inspect(reason)}"
        )

        @empty_config
    end
  end

  # Reconstructs the actually-running state from live `AssetWorker`s — the
  # counterpart to loading the *desired* state from disk, used only by
  # `init/1` (see moduledoc). `defaults` is always `nil`: every live worker's
  # `asset`/`rules` already have Defaults resolved into them (interval,
  # cooldown), so there is nothing left for a `Defaults` resource to
  # contribute here.
  @spec actual_from_runtime() :: Config.t()
  defp actual_from_runtime do
    states =
      WorkersSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.flat_map(&fetch_worker_state/1)

    %Config{
      assets: Map.new(states, fn state -> {state.asset.name, state.asset} end),
      rules: rules_from_states(states),
      notifiers: notifiers_from_states(states),
      defaults: nil
    }
  end

  # A worker that cannot answer (dead, restarting, or a `GenServer.call`
  # timeout) is skipped rather than guessed at: it simply will not appear in
  # `actual`, so the next diff treats it as `added` again — the same outcome
  # `init/1` always produced for every asset before this reconstruction
  # existed, just narrowed to the one worker that could not answer.
  #
  # Public (with `@doc false`) so both branches are directly unit-testable —
  # mirrors `Control.accept_loop/2`/`accept_error_action/1`, which are exposed
  # the same way to drive edge cases without inducing real timing races.
  @doc false
  @spec fetch_worker_state({term(), pid() | term(), :worker, [module()] | :dynamic}) :: [map()]
  def fetch_worker_state({_id, pid, :worker, _modules}) when is_pid(pid) do
    [AssetWorker.state(pid)]
  catch
    :exit, _reason -> []
  end

  def fetch_worker_state(_child), do: []

  @spec rules_from_states([map()]) :: %{String.t() => Config.Rule.t()}
  defp rules_from_states(states) do
    states
    |> Enum.flat_map(& &1.rules)
    |> Map.new(&{&1.name, &1})
  end

  # Notifiers are a global CRD resource (RFC-0003), not per-asset, and a
  # successful in-place update applies the same `desired.notifiers` map to
  # every affected worker in one pass — so in the common case every live
  # worker's `channel_configs` already agree. They can only diverge if a
  # *previous* reload's apply step failed for some assets and not others
  # (`applied.failed`); reconstructing "the" actual notifier set is then
  # inherently approximate. Picking the alphabetically-first asset's
  # `channel_configs` keeps this deterministic rather than depending on
  # `DynamicSupervisor.which_children/1`'s unspecified ordering.
  @spec notifiers_from_states([map()]) :: %{String.t() => Vigil.Core.Config.Telegram.t()}
  defp notifiers_from_states([]), do: %{}

  defp notifiers_from_states(states) do
    states
    |> Enum.min_by(& &1.asset.name)
    |> Map.fetch!(:channel_configs)
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

  # `stop_worker/1` terminates synchronously, but `Registry` clears the old
  # `:via` name asynchronously (see `@deregister_timeout_ms`) — without
  # waiting, `start_worker/2` can race the stale entry and collide with the
  # very process it just told to stop (`{:error, {:already_started, dying_pid}}`).
  @spec restart_worker(Config.t(), String.t()) :: :ok | {:error, term()}
  defp restart_worker(desired, name) do
    with :ok <- stop_worker(name),
         :ok <- await_deregistered(name) do
      start_worker(desired, name)
    end
  end

  # Public (with `@doc false`) so the polling branch is directly
  # unit-testable with a controlled, short-lived registration instead of
  # depending on the real (and inherently non-deterministic) timing gap
  # between `stop_worker/1` returning and `Registry`'s own monitor clearing
  # the name — mirrors `fetch_worker_state/1` above.
  @doc false
  @spec await_deregistered(String.t()) :: :ok | {:error, :deregister_timeout}
  def await_deregistered(name), do: await_deregistered(name, System.monotonic_time(:millisecond))

  @spec await_deregistered(String.t(), integer()) :: :ok | {:error, :deregister_timeout}
  defp await_deregistered(name, started_at) do
    case worker_pid(name) do
      :error ->
        :ok

      {:ok, _pid} ->
        if System.monotonic_time(:millisecond) - started_at >= @deregister_timeout_ms do
          {:error, :deregister_timeout}
        else
          Process.sleep(@deregister_poll_interval_ms)
          await_deregistered(name, started_at)
        end
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
