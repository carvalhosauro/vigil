defmodule Vigil.Core.ContextTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Context
  alias Vigil.Core.MarketSnapshot

  defp snapshot(overrides \\ []) do
    defaults = [
      symbol: "PETR4.SA",
      timestamp: ~U[2026-07-01 10:30:00Z],
      open: 37.90,
      high: 38.60,
      low: 37.80,
      close: 38.42,
      price: 38.42,
      volume: 845_231
    ]

    struct!(MarketSnapshot, Keyword.merge(defaults, overrides))
  end

  describe "build/2 derived metrics" do
    test "computes change, change_percent and daily_range" do
      ctx = Context.build(snapshot(), asset: "petr4", provider: "yahoo")

      assert_in_delta ctx.derived.change, 0.52, 0.001
      assert_in_delta ctx.derived.change_percent, 1.372, 0.01
      assert_in_delta ctx.derived.daily_range, 0.80, 0.001
    end

    test "change_percent is 0.0 when open is zero" do
      ctx = Context.build(snapshot(open: 0.0, price: 5.0), asset: "petr4", provider: "yahoo")

      assert ctx.derived.change_percent == 0.0
    end

    test "change and change_percent are nil when the snapshot has no open" do
      ctx = Context.build(snapshot(open: nil), asset: "petr4", provider: "yahoo")

      assert ctx.derived.change == nil
      assert ctx.derived.change_percent == nil
    end

    test "volume_delta is nil on the first cycle" do
      ctx = Context.build(snapshot(), asset: "petr4", provider: "yahoo")

      assert ctx.derived.volume_delta == nil
    end

    test "volume_delta is the difference from the previous snapshot" do
      previous = snapshot(volume: 100)
      current = snapshot(volume: 250)

      ctx =
        Context.build(current,
          asset: "petr4",
          provider: "yahoo",
          previous_snapshot: previous
        )

      assert ctx.derived.volume_delta == 150
    end
  end

  describe "build/2 structure" do
    test "carries metadata from options and the snapshot timestamp" do
      ctx =
        Context.build(snapshot(), asset: "petr4", provider: "yahoo", polling_interval: "30s")

      assert ctx.metadata.asset == "petr4"
      assert ctx.metadata.provider == "yahoo"
      assert ctx.metadata.polling_interval == "30s"
      assert ctx.metadata.timestamp == ~U[2026-07-01 10:30:00Z]
    end

    test "keeps the raw market snapshot untouched" do
      snap = snapshot()
      ctx = Context.build(snap, asset: "petr4", provider: "yahoo")

      assert ctx.market == snap
    end

    test "starts with an empty indicators collection" do
      ctx = Context.build(snapshot(), asset: "petr4", provider: "yahoo")

      assert ctx.indicators == %{}
    end
  end
end
