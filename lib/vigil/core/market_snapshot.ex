defmodule Vigil.Core.MarketSnapshot do
  @moduledoc """
  Raw market data obtained from a Provider, normalized to Vigil's internal shape.

  Contains only information coming from the market — no calculations. See RFC-0004 §7.
  """

  @enforce_keys [:symbol, :timestamp, :open, :high, :low, :close, :price, :volume]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          symbol: String.t(),
          timestamp: DateTime.t(),
          open: float(),
          high: float(),
          low: float(),
          close: float(),
          price: float(),
          volume: non_neg_integer()
        }
end
