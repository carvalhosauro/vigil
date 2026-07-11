defmodule Vigil.Adapters.Notifier.MessageTest do
  use ExUnit.Case, async: true

  alias Vigil.Adapters.Notifier.Message
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

  defp rule(name \\ "breakout") do
    %Rule{name: name, asset: "petr4", condition: %{}, actions: ["telegram"], cooldown: "5m"}
  end

  describe "render/2" do
    test "renders the RFC-0007 §7 default template deterministically" do
      message = Message.render(rule(), context())

      assert message == Message.render(rule(), context())
      assert message =~ "petr4 — breakout"
      assert message =~ "price: 40.12"
      assert message =~ "2026-07-01 10:30"
    end

    test "caps the message at 4096 characters (Telegram sendMessage limit)" do
      long_name = String.duplicate("a", 5_000)
      message = Message.render(rule(long_name), context())

      assert String.length(message) == 4096
    end
  end
end
