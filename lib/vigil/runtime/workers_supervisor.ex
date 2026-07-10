defmodule Vigil.Runtime.WorkersSupervisor do
  @moduledoc """
  Sub-supervisor that isolates AssetWorker crashes from the rest of the Runtime
  topology (RFC-0015 §8, RFC-0013 DEC-002).

  A high-intensity ceiling (50 restarts / 10 s) ensures a single misbehaving
  asset does not tear down siblings or the Task.Supervisors that sit above it.
  """

  use Supervisor

  def start_link(workers) do
    Supervisor.start_link(__MODULE__, workers, name: __MODULE__)
  end

  @impl Supervisor
  def init(workers) do
    Supervisor.init(workers, strategy: :one_for_one, max_restarts: 50, max_seconds: 10)
  end
end
