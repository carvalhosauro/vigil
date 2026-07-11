defmodule Vigil.Runtime.CycleReport do
  @moduledoc """
  Summary of one executed cycle (RFC-0015 §6): what was fetched, evaluated,
  dispatched and how state advanced.
  """

  @enforce_keys [:asset, :outcome]
  defstruct [
    :asset,
    :outcome,
    :error,
    attempts: 1,
    triggered: [],
    notified: [],
    suppressed: []
  ]

  @type t :: %__MODULE__{
          asset: String.t(),
          outcome: :ok | :failed,
          error: Vigil.Adapters.Provider.Error.t() | nil,
          attempts: pos_integer(),
          triggered: [String.t()],
          notified: [String.t()],
          suppressed: [String.t()]
        }
end
