defmodule Vigil.Runtime.SupervisorTest do
  use ExUnit.Case, async: false

  alias Vigil.Core.MarketSnapshot

  defmodule StubProvider do
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

  setup do
    System.put_env("TELEGRAM_TOKEN", "tok")
    System.put_env("CHAT_ID", "123")
    Application.put_env(:vigil, :providers, %{"yahoo" => StubProvider})

    on_exit(fn ->
      System.delete_env("TELEGRAM_TOKEN")
      System.delete_env("CHAT_ID")
      Application.delete_env(:vigil, :providers)
    end)
  end

  test "boots one worker per asset from a valid config dir" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])

    start_supervised!({Vigil.Runtime.Supervisor, config_dir: "test/fixtures/configs_valid"})

    assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 5_000
  end

  test "fails fast on a missing config dir with a clean error shape" do
    assert {:error, {:invalid_config, _reason}} =
             Vigil.Runtime.Supervisor.start_link(config_dir: "test/fixtures/nope")
  end
end
