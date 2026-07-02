defmodule Vigil.Adapters.Provider.YahooTest do
  use ExUnit.Case, async: true

  alias Plug.Conn
  alias Req.Test
  alias Vigil.Adapters.Provider.Yahoo
  alias Vigil.Core.Config.Asset
  alias Vigil.Core.MarketSnapshot

  @stub :yahoo_provider_test
  @asset %Asset{name: "petr4", symbol: "PETR4.SA", provider: "yahoo", interval: "30s"}

  defp fixture(name) do
    path = Path.join([__DIR__, "..", "..", "..", "fixtures", "yahoo", name])
    path |> File.read!() |> Jason.decode!()
  end

  defp stub_json(body) do
    Test.stub(@stub, fn conn ->
      Test.json(conn, body)
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

  defp fetch_opts do
    [plug: {Test, @stub}]
  end

  test "fetch/1 returns a normalized market snapshot" do
    stub_json(fixture("petr4_sa_success.json"))

    assert {:ok, %MarketSnapshot{} = snapshot} = Yahoo.fetch(@asset, fetch_opts())

    assert snapshot.symbol == "PETR4.SA"
    assert snapshot.timestamp == ~U[2024-07-01 11:30:00Z]
    assert snapshot.open == 37.9
    assert snapshot.high == 38.6
    assert snapshot.low == 37.8
    assert snapshot.price == 38.42
    assert snapshot.close == 38.42
    assert snapshot.volume == 845_231
  end

  test "close equals price for point-in-time poll" do
    stub_json(fixture("petr4_sa_success.json"))

    assert {:ok, snapshot} = Yahoo.fetch(@asset, fetch_opts())
    assert snapshot.close == snapshot.price
  end

  test "returns invalid_response when chart error is not found" do
    stub_json(fixture("symbol_not_found.json"))

    assert {:error, %{category: :invalid_response, symbol: "PETR4.SA"}} =
             Yahoo.fetch(@asset, fetch_opts())
  end

  test "returns unavailable for other chart errors" do
    stub_json(fixture("chart_error.json"))

    assert {:error, %{category: :unavailable}} = Yahoo.fetch(@asset, fetch_opts())
  end

  test "returns invalid_response when required meta fields are missing" do
    stub_json(fixture("missing_fields.json"))

    assert {:error, %{category: :invalid_response, details: %{missing: ["regularMarketVolume"]}}} =
             Yahoo.fetch(@asset, fetch_opts())
  end

  test "returns invalid_response for malformed JSON body" do
    Test.stub(@stub, fn conn ->
      Test.text(conn, "not-json")
    end)

    assert {:error, %{category: :invalid_response}} = Yahoo.fetch(@asset, fetch_opts())
  end

  test "returns invalid_response for http 404" do
    stub_status(404)

    assert {:error, %{category: :invalid_response, message: "yahoo symbol not found"}} =
             Yahoo.fetch(@asset, fetch_opts())
  end

  test "returns rate_limit for http 429" do
    stub_status(429)

    assert {:error, %{category: :rate_limit}} = Yahoo.fetch(@asset, fetch_opts())
  end

  test "returns unavailable for http 503" do
    stub_status(503)

    assert {:error, %{category: :unavailable}} = Yahoo.fetch(@asset, fetch_opts())
  end

  test "returns authentication for http 401" do
    stub_status(401)

    assert {:error, %{category: :authentication}} = Yahoo.fetch(@asset, fetch_opts())
  end

  test "returns timeout on transport timeout" do
    stub_transport_error(:timeout)

    assert {:error, %{category: :timeout}} = Yahoo.fetch(@asset, fetch_opts())
  end

  test "returns network on other transport errors" do
    stub_transport_error(:econnrefused)

    assert {:error, %{category: :network, details: %{reason: :econnrefused}}} =
             Yahoo.fetch(@asset, fetch_opts())
  end

  test "behaviour callback fetch/1 uses configured req options" do
    stub_json(fixture("petr4_sa_success.json"))

    previous = Application.get_env(:vigil, Vigil.Adapters.Provider, [])

    Application.put_env(
      :vigil,
      Vigil.Adapters.Provider,
      Keyword.put(previous, :req_options, fetch_opts())
    )

    on_exit(fn -> Application.put_env(:vigil, Vigil.Adapters.Provider, previous) end)

    assert {:ok, %MarketSnapshot{symbol: "PETR4.SA"}} = Yahoo.fetch(@asset)
  end
end
