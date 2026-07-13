defmodule Vigil.Runtime.WorkersSupervisor do
  @moduledoc """
  Sub-supervisor that isolates AssetWorker crashes from the rest of the Runtime
  topology (RFC-0015 §8, RFC-0013 DEC-002).

  A `DynamicSupervisor` (RFC-0006 D2): assets are started, stopped, and
  restarted at runtime as the `Vigil.Runtime.Reconciler` reconciles config
  changes. Workers are addressed by asset name through
  `Vigil.Runtime.WorkerRegistry`, since a `DynamicSupervisor` does not track
  children by a caller-chosen id the way a static `Supervisor` does.

  A high-intensity ceiling (50 restarts / 10 s) ensures a single misbehaving
  asset does not tear down siblings or the Task.Supervisors that sit above it.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 50, max_seconds: 10)
  end
end
