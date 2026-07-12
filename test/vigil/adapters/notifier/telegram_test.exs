defmodule Vigil.Adapters.Notifier.TelegramTest do
  use ExUnit.Case, async: false

  alias Plug.Conn
  alias Req.Test
  alias Vigil.Adapters.Notifier.Telegram
  alias Vigil.Core.Config
  alias Vigil.Core.Config.Rule
  alias Vigil.Core.{Context, MarketSnapshot}

  @stub :telegram_notifier_test
  @token "123456:ABC-DEF"
  @chat_id "-100200300"

  setup do
    System.put_env("TELEGRAM_TOKEN", @token)
    System.put_env("TELEGRAM_CHAT_ID", @chat_id)

    on_exit(fn ->
      System.delete_env("TELEGRAM_TOKEN")
      System.delete_env("TELEGRAM_CHAT_ID")
    end)

    :ok
  end

  defp channel_config(overrides \\ []) do
    struct!(
      Config.Telegram,
      Keyword.merge(
        [name: "telegram", token: "${TELEGRAM_TOKEN}", chat_id: "${TELEGRAM_CHAT_ID}"],
        overrides
      )
    )
  end

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

  defp rule do
    %Rule{name: "breakout", asset: "petr4", condition: %{}, actions: ["telegram"], cooldown: "5m"}
  end

  defp stub_json(body, status \\ 200) do
    Test.stub(@stub, fn conn ->
      conn |> Conn.put_status(status) |> Test.json(body)
    end)
  end

  defp stub_status(status) do
    Test.stub(@stub, fn conn ->
      Conn.send_resp(conn, status, "")
    end)
  end

  defp stub_transport_error(reason) do
    Test.stub(@stub, fn conn ->
      Test.transport_error(conn, reason)
    end)
  end

  defp notify_opts do
    [plug: {Test, @stub}]
  end

  test "notify/4 delivers a plain-text message and returns the message id" do
    Test.stub(@stub, fn conn ->
      {:ok, raw_body, conn} = Conn.read_body(conn)
      body = Jason.decode!(raw_body)

      assert conn.request_path == "/bot#{@token}/sendMessage"
      assert body["chat_id"] == @chat_id
      assert body["text"] =~ "petr4 — breakout"
      refute Map.has_key?(body, "parse_mode")

      Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 42}})
    end)

    assert {:ok, %{channel: "telegram", message_id: 42}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "returns authentication error for http 401 without echoing description" do
    stub_json(
      %{
        "ok" => false,
        "error_code" => 401,
        "description" => "Unauthorized: super secret leak"
      },
      401
    )

    assert {:error, error} = Telegram.notify(rule(), context(), channel_config(), notify_opts())
    assert error.category == :authentication
    assert error.message == "telegram authentication failed"
    refute inspect(error) =~ "secret"
    refute inspect(error) =~ @token
  end

  test "returns authentication error for http 404" do
    stub_status(404)

    assert {:error, %{category: :authentication, message: "telegram authentication failed"}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "returns invalid_target for http 400 (chat not found)" do
    stub_json(
      %{
        "ok" => false,
        "error_code" => 400,
        "description" => "Bad Request: chat not found"
      },
      400
    )

    assert {:error, %{category: :invalid_target, message: "Bad Request: chat not found"}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "returns invalid_target for http 403 (bot blocked)" do
    stub_json(
      %{
        "ok" => false,
        "error_code" => 403,
        "description" => "Forbidden: bot was blocked by the user"
      },
      403
    )

    assert {:error,
            %{category: :invalid_target, message: "Forbidden: bot was blocked by the user"}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "returns rate_limit for http 429 and converts retry_after seconds to ms" do
    stub_json(
      %{
        "ok" => false,
        "error_code" => 429,
        "description" => "Too Many Requests: retry later",
        "parameters" => %{"retry_after" => 3}
      },
      429
    )

    assert {:error, %{category: :rate_limit, details: %{retry_after_ms: 3_000}}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "returns invalid_target with a default message when 400 body has no description" do
    stub_json(%{"ok" => false, "error_code" => 400}, 400)

    assert {:error, %{category: :invalid_target, message: "telegram chat not found"}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "returns rate_limit without retry_after_ms when parameters are absent" do
    stub_json(%{"ok" => false, "error_code" => 429}, 429)

    assert {:error, %{category: :rate_limit, details: %{status: 429}} = error} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())

    refute Map.has_key?(error.details, :retry_after_ms)
  end

  test "returns invalid_response for a malformed JSON body advertised as JSON" do
    Test.stub(@stub, fn conn ->
      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(200, "not-json")
    end)

    assert {:error, %{category: :invalid_response}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "returns unavailable for http 500" do
    stub_status(500)

    assert {:error, %{category: :unavailable}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "returns invalid_response for unexpected 200 body shape" do
    stub_json(%{"ok" => true})

    assert {:error, %{category: :invalid_response}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "returns timeout on transport timeout" do
    stub_transport_error(:timeout)

    assert {:error, error} = Telegram.notify(rule(), context(), channel_config(), notify_opts())
    assert error.category == :timeout
    refute inspect(error) =~ @token
  end

  test "returns network on other transport errors" do
    stub_transport_error(:econnrefused)

    assert {:error, %{category: :network, details: %{reason: :econnrefused}}} =
             Telegram.notify(rule(), context(), channel_config(), notify_opts())
  end

  test "reduces unknown request errors to their type without echoing the request" do
    # An adapter returning an error term this module does not classify — the
    # exception embeds the request (and so the token-bearing URL).
    adapter = fn request ->
      {request, %RuntimeError{message: "boom #{request.url}"}}
    end

    assert {:error, error} =
             Telegram.notify(rule(), context(), channel_config(), adapter: adapter)

    assert error.category == :invalid_response
    assert error.details.reason == "RuntimeError"
    refute inspect(error) =~ @token
  end

  test "returns configuration error with the var name when token env var is missing" do
    System.delete_env("TELEGRAM_TOKEN")

    assert {:error, error} = Telegram.notify(rule(), context(), channel_config(), notify_opts())
    assert error.category == :configuration
    assert error.details.env_var == "TELEGRAM_TOKEN"
    refute inspect(error) =~ @token
  end

  test "returns configuration error with the var name when chat_id env var is missing" do
    System.delete_env("TELEGRAM_CHAT_ID")

    assert {:error, error} = Telegram.notify(rule(), context(), channel_config(), notify_opts())
    assert error.category == :configuration
    assert error.details.env_var == "TELEGRAM_CHAT_ID"
  end

  test "behaviour callback notify/3 uses configured req options" do
    stub_json(%{"ok" => true, "result" => %{"message_id" => 7}})

    previous = Application.get_env(:vigil, Vigil.Adapters.Notifier, [])

    Application.put_env(
      :vigil,
      Vigil.Adapters.Notifier,
      Keyword.put(previous, :req_options, notify_opts())
    )

    on_exit(fn -> Application.put_env(:vigil, Vigil.Adapters.Notifier, previous) end)

    assert {:ok, %{channel: "telegram", message_id: 7}} =
             Telegram.notify(rule(), context(), channel_config())
  end
end
