defmodule Vigil.Runtime do
  @moduledoc """
  The Runtime — executes the monitoring cycle (RFC-0015).

  Orchestrates Scheduler trigger → Provider fetch → Context → Rule Engine →
  dispatch → State, one supervised worker per Asset. Owns retry, backoff,
  overlap skipping and the cycle timeout ceiling. Never implements domain
  logic (RFC-0015 §3).
  """
  use Boundary,
    top_level?: true,
    deps: [Vigil.Core, Vigil.Adapters],
    exports: [Supervisor]
end
