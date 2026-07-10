defmodule Vigil.Runtime.Supervisor do
  @moduledoc """
  Boots the Runtime: loads the configuration (fail-fast — an invalid or
  missing configuration aborts application start, RFC-0010 DEC-003) and starts
  one `AssetWorker` per Asset.

  Workers are static children this milestone: reconciliation on config change
  (RFC-0015 §13, RFC-0006) is a future milestone.
  """

  use Supervisor

  alias Vigil.Adapters.ConfigLoader
  alias Vigil.Runtime.AssetWorker

  @cycle_task_supervisor Vigil.Runtime.CycleTaskSupervisor
  @dispatch_task_supervisor Vigil.Runtime.DispatchTaskSupervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    dir = Keyword.get(opts, :config_dir, ConfigLoader.config_dir())

    case ConfigLoader.load(dir) do
      {:ok, config} ->
        Supervisor.init(children(config), strategy: :one_for_one)

      {:error, reason} ->
        {:stop, {:invalid_config, reason}}
    end
  end

  defp children(config) do
    task_supervisors = [
      {Task.Supervisor, name: @cycle_task_supervisor},
      {Task.Supervisor, name: @dispatch_task_supervisor}
    ]

    workers =
      Enum.map(config.assets, fn {name, asset} ->
        rules = for {_rule_name, rule} <- config.rules, rule.asset == name, do: rule

        Supervisor.child_spec(
          {AssetWorker,
           asset: asset,
           rules: rules,
           cycle_task_supervisor: @cycle_task_supervisor,
           dispatch_task_supervisor: @dispatch_task_supervisor},
          id: {AssetWorker, name}
        )
      end)

    task_supervisors ++ workers
  end
end
