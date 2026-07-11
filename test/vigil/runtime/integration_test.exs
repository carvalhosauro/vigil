defmodule Vigil.Runtime.IntegrationTest do
  use ExUnit.Case, async: false

  alias Vigil.Core.MarketSnapshot

  defmodule BreakoutProvider do
    def fetch(_asset) do
      {:ok,
       struct!(MarketSnapshot,
         symbol: "PETR4.SA",
         timestamp: DateTime.utc_now(),
         open: 39.0,
         high: 41.0,
         low: 38.5,
         close: 39.0,
         price: 40.12,
         volume: 1_000
       )}
    end
  end

  test "a satisfied rule produces exactly one notification.sent through the log notifier" do
    System.put_env("TELEGRAM_TOKEN", "tok")
    System.put_env("CHAT_ID", "123")
    Application.put_env(:vigil, :providers, %{"yahoo" => BreakoutProvider})
    Application.put_env(:vigil, :notifiers, %{"telegram" => Vigil.Adapters.Notifier.Log})

    on_exit(fn ->
      System.delete_env("TELEGRAM_TOKEN")
      System.delete_env("CHAT_ID")
      Application.delete_env(:vigil, :providers)
      Application.delete_env(:vigil, :notifiers)
    end)

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vigil, :notification, :sent],
        [:vigil, :runtime, :cycle, :finished]
      ])

    start_supervised!({Vigil.Runtime.Supervisor, config_dir: "test/fixtures/configs_fast"})

    # first cycle: breakout fires (40.12 > 40) and is delivered by the log notifier
    assert_receive {[:vigil, :notification, :sent], ^ref, _,
                    %{asset: "petr4", rule: "breakout", delivery: %{channel: "log"}}},
                   5_000

    # cooldown + still-satisfied suppression: no second delivery on later cycles
    assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 5_000
    refute_receive {[:vigil, :notification, :sent], ^ref, _, _}, 1_500
  end
end
