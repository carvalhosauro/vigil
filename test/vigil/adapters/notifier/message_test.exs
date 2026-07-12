defmodule Vigil.Adapters.Notifier.MessageTest do
  use ExUnit.Case, async: true

  alias Vigil.Adapters.Notifier.Message
  alias Vigil.Core.Config.Rule
  alias Vigil.Core.{Context, MarketSnapshot}

  defp context(overrides \\ []) do
    snapshot =
      struct!(
        MarketSnapshot,
        Keyword.merge(
          [
            symbol: "PETR4.SA",
            timestamp: ~U[2026-07-01 10:30:00Z],
            open: 38.80,
            high: 40.50,
            low: 38.60,
            close: 38.80,
            price: 40.12,
            volume: 845_231
          ],
          overrides
        )
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

    test "renders a negative change with its own sign" do
      message = Message.render(rule(), context(open: 41.00))

      assert message =~ "(-2.1%)"
    end

    test "renders n/a when change_percent is nil (nil open, RFC-0001 §12)" do
      message = Message.render(rule(), context(open: nil))

      assert message =~ "(n/a)"
    end

    test "caps the message at 4096 UTF-16 code units (Telegram sendMessage limit)" do
      long_name = String.duplicate("a", 5_000)
      message = Message.render(rule(long_name), context())

      assert utf16_units(message) == 4096
    end

    test "counts supplementary-plane characters as two UTF-16 units when capping" do
      # 🚨 is 2 UTF-16 units; a name of ~4600 emoji overflows the cap in
      # units long before it reaches 4096 graphemes.
      long_name = String.duplicate("🚨", 4_600)
      message = Message.render(rule(long_name), context())

      assert utf16_units(message) <= 4096
      assert String.length(message) < 4096
    end

    defp utf16_units(string) do
      string
      |> String.to_charlist()
      |> Enum.reduce(0, fn codepoint, acc ->
        acc + if codepoint > 0xFFFF, do: 2, else: 1
      end)
    end
  end
end
