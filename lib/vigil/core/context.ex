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

  Required options: `:asset`, `:provider`.

  Optional: `:polling_interval`, `:runtime`, `:previous_snapshot` (for `volume_delta`).
  """
  @spec build(MarketSnapshot.t(), keyword()) :: t()
  def build(%MarketSnapshot{} = snapshot, opts) do
    previous_snapshot = Keyword.get(opts, :previous_snapshot)

    %__MODULE__{
      metadata: %{
        asset: Keyword.fetch!(opts, :asset),
        provider: Keyword.fetch!(opts, :provider),
        timestamp: snapshot.timestamp,
        polling_interval: Keyword.get(opts, :polling_interval)
      },
      market: snapshot,
      derived: derive(snapshot, previous_snapshot),
      indicators: %{},
      runtime: Keyword.get(opts, :runtime, %{})
    }
  end

  @spec derive(MarketSnapshot.t(), MarketSnapshot.t() | nil) :: Derived.t()
  defp derive(%MarketSnapshot{} = s, previous_snapshot) do
    %Derived{
      change: change(s),
      change_percent: change_percent(s),
      daily_range: s.high - s.low,
      volume_delta: volume_delta(s, previous_snapshot)
    }
  end

  @spec change(MarketSnapshot.t()) :: number() | nil
  defp change(%MarketSnapshot{open: nil}), do: nil
  defp change(%MarketSnapshot{} = s), do: s.price - s.open

  @spec change_percent(MarketSnapshot.t()) :: float() | nil
  defp change_percent(%MarketSnapshot{open: nil}), do: nil
  defp change_percent(%MarketSnapshot{} = s), do: percent(s.price - s.open, s.open)

  @spec volume_delta(MarketSnapshot.t(), MarketSnapshot.t() | nil) :: number() | nil
  defp volume_delta(_current, nil), do: nil

  defp volume_delta(%MarketSnapshot{} = current, %MarketSnapshot{} = previous),
    do: current.volume - previous.volume

  @spec percent(float(), float()) :: float()
  defp percent(_change, open) when open == 0, do: 0.0
  defp percent(change, open), do: change / open * 100
end
