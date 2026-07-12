defmodule Vigil.Adapters.Notifier.LogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vigil.Adapters.Notifier.Log
  alias Vigil.Core.Config.Rule
  alias Vigil.Core.{Context, MarketSnapshot}

  defp context do
    snapshot =
      struct!(MarketSnapshot,
        symbol: "PETR4.SA",
        timestamp: ~U[2026-07-01 10:30:00Z],
        open: 38.80,
        high: 40.50,
        low: 38.60,
        close: 38.80,
        price: 40.12,
        volume: 845_231
      )

    Context.build(snapshot, asset: "petr4", provider: "yahoo")
  end

  defp rule do
    %Rule{name: "breakout", asset: "petr4", condition: %{}, actions: ["telegram"], cooldown: "5m"}
  end

  describe "notify/3" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    test "logs the rendered message and returns the delivery" do
      log =
        capture_log(fn ->
          assert {:ok, %{channel: "log", message: message}} =
                   Log.notify(rule(), context(), nil)

          assert message =~ "breakout"
        end)

      assert log =~ "petr4 — breakout"
    end

    test "ignores the channel config" do
      capture_log(fn ->
        assert {:ok, _} = Log.notify(rule(), context(), %{any: :config})
      end)
    end
  end
end
