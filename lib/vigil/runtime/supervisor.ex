defmodule Vigil.Runtime.Supervisor do
  @moduledoc """
  Boots the Runtime: validates the configuration once (fail-fast — an invalid
  or missing configuration aborts application start, RFC-0010 DEC-003), then
  hands the `Reconciler` only the config *directory*. The Reconciler loads
  from disk itself and starts one `AssetWorker` per Asset (RFC-0006: boot is
  an initial reconcile against an empty actual config). Passing the directory
  rather than a boot-time snapshot means a Reconciler restart re-syncs to the
  current on-disk source of truth (DEC-001) instead of reverting to boot.

  Topology (`:rest_for_one`):
    CycleTaskSupervisor
    DispatchTaskSupervisor
    WorkerRegistry     ← names AssetWorkers by asset (survives crash-restarts)
    WorkersSupervisor  ← dynamic, high-intensity sub-supervisor; isolates
                          asset crashes; populated by the Reconciler
      └─ AssetWorker × N
    Reconciler         ← owns the actual config; reconciles config reloads
                          (RFC-0006), one path for FS-watch and CLI (DEC-006)
    Control            ← control channel socket (RFC-0010 §13); started last so
                          a `status` request never races worker boot.
  """

  use Supervisor

  alias Vigil.Adapters.ConfigLoader
  alias Vigil.Runtime.{Control, Reconciler, WorkersSupervisor}

  @cycle_task_supervisor Vigil.Runtime.CycleTaskSupervisor
  @dispatch_task_supervisor Vigil.Runtime.DispatchTaskSupervisor
  @worker_registry Vigil.Runtime.WorkerRegistry

  def start_link(opts) do
    dir = Keyword.get(opts, :config_dir, ConfigLoader.config_dir())

    case ConfigLoader.load(dir) do
      {:ok, _config} ->
        Supervisor.start_link(__MODULE__, dir, name: __MODULE__)

      {:error, reason} ->
        {:error, {:invalid_config, reason}}
    end
  end

  @impl Supervisor
  def init(dir) do
    Supervisor.init(children(dir), strategy: :rest_for_one)
  end

  defp children(dir) do
    [
      {Task.Supervisor, name: @cycle_task_supervisor},
      {Task.Supervisor, name: @dispatch_task_supervisor},
      {Registry, keys: :unique, name: @worker_registry},
      WorkersSupervisor,
      {Reconciler, config_dir: dir},
      Control
    ]
  end
end
