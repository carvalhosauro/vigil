defmodule Vigil.Core.Context do
  @moduledoc """
  The complete, immutable state of an asset at a point in time.

  Every Rule is evaluated exclusively against a Context. It consolidates the
  market snapshot, derived metrics, indicators and runtime state. See RFC-0002.
  """

  alias Vigil.Core.Derived
  alias Vigil.Core.MarketSnapshot

  @enforce_keys [:metadata, :market, :derived, :indicators, :runtime]
  defstruct @enforce_keys

  @type metadata :: %{
          asset: String.t(),
          provider: String.t(),
          timestamp: DateTime.t(),
          polling_interval: String.t() | nil
        }

  @type t :: %__MODULE__{
          metadata: metadata(),
          market: MarketSnapshot.t(),
          derived: Derived.t(),
          indicators: %{optional(atom()) => number()},
          runtime: map()
        }

  @doc """
  Builds a Context from a `MarketSnapshot`.

  Required options: `:asset`, `:provider`. Optional: `:polling_interval`, `:runtime`.
  """
  @spec build(MarketSnapshot.t(), keyword()) :: t()
  def build(%MarketSnapshot{} = snapshot, opts) do
    %__MODULE__{
      metadata: %{
        asset: Keyword.fetch!(opts, :asset),
        provider: Keyword.fetch!(opts, :provider),
        timestamp: snapshot.timestamp,
        polling_interval: Keyword.get(opts, :polling_interval)
      },
      market: snapshot,
      derived: derive(snapshot),
      indicators: %{},
      runtime: Keyword.get(opts, :runtime, %{})
    }
  end

  @spec derive(MarketSnapshot.t()) :: Derived.t()
  defp derive(%MarketSnapshot{} = s) do
    change = s.price - s.open

    %Derived{
      change: change,
      change_percent: percent(change, s.open),
      daily_range: s.high - s.low,
      volume_delta: nil
    }
  end

  @spec percent(float(), float()) :: float()
  defp percent(_change, open) when open == 0, do: 0.0
  defp percent(change, open), do: change / open * 100
end
