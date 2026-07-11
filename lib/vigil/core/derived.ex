defmodule Vigil.Core.Derived do
  @moduledoc """
  Simple metrics derived from a `Vigil.Core.MarketSnapshot`.

  Independent of any Provider. See RFC-0002 §8. `volume_delta` requires the
  previous snapshot and is populated once State Management exists (RFC-0012).
  `change` and `change_percent` are `nil` when the snapshot has no `open`
  (metric not available — rules referencing them do not fire, RFC-0001 §12).
  """

  @enforce_keys [:change, :change_percent, :daily_range]
  defstruct [:change, :change_percent, :daily_range, :volume_delta]

  @type t :: %__MODULE__{
          change: float() | nil,
          change_percent: float() | nil,
          daily_range: float(),
          volume_delta: number() | nil
        }
end
