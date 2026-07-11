defmodule Vigil.Core.MarketSnapshot do
  @moduledoc """
  Raw market data obtained from a Provider, normalized to Vigil's internal shape.

  Contains only information coming from the market — no calculations. See RFC-0004 §7.

  `open` is `nil` when the provider does not expose the session open (e.g. Yahoo
  outside regular trading hours); Vigil never fabricates it.

  `market_open` reflects the provider's market state when exposed, defaulting to `true`
  (RFC-0015 DEC-010).
  """

  @enforce_keys [:symbol, :timestamp, :open, :high, :low, :close, :price, :volume]
  defstruct @enforce_keys ++ [market_open: true]

  @type t :: %__MODULE__{
          symbol: String.t(),
          timestamp: DateTime.t(),
          open: float() | nil,
          high: float(),
          low: float(),
          close: float(),
          price: float(),
          volume: non_neg_integer(),
          market_open: boolean()
        }
end
