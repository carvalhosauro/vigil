defmodule Vigil.Core.MarketSnapshotTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.MarketSnapshot

  test "holds OHLC, price and volume" do
    snapshot = %MarketSnapshot{
      symbol: "PETR4.SA",
      timestamp: ~U[2026-07-01 10:30:00Z],
      open: 37.90,
      high: 38.60,
      low: 37.80,
      close: 38.42,
      price: 38.42,
      volume: 845_231
    }

    assert snapshot.symbol == "PETR4.SA"
    assert snapshot.price == 38.42
    assert snapshot.volume == 845_231
  end

  test "raises when a required field is missing" do
    assert_raise ArgumentError, fn ->
      struct!(MarketSnapshot, symbol: "PETR4.SA")
    end
  end

  test "market_open defaults to true" do
    snapshot =
      struct!(MarketSnapshot,
        symbol: "PETR4.SA",
        timestamp: ~U[2026-07-01 10:30:00Z],
        open: 1.0,
        high: 1.0,
        low: 1.0,
        close: 1.0,
        price: 1.0,
        volume: 1
      )

    assert snapshot.market_open == true
  end
end
