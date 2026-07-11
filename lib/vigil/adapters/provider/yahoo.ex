defmodule Vigil.Adapters.Provider.Yahoo do
  @moduledoc """
  Yahoo Finance market data provider (v1).

  Uses the public chart API (`/v8/finance/chart/{symbol}`). Data may be delayed
  and the endpoint is unofficial — no SLA guarantees (see ROADMAP).

  Snapshot semantics for a point-in-time poll:

    * `price` maps to `regularMarketPrice` (the last price).
    * `close` maps to `chartPreviousClose`/`previousClose` (the previous session
      close), falling back to `price` when the API omits both.
    * OHLCV fields are taken from `meta` without further calculation.

  Telemetry (`provider.request.*`) is documented on the behaviour and wired in
  Phase 8 — not emitted here.
  """

  @behaviour Vigil.Adapters.Provider

  alias Vigil.Adapters.Provider.Error
  alias Vigil.Core.Config.Asset
  alias Vigil.Core.MarketSnapshot

  @provider "yahoo"
  @base_url "https://query1.finance.yahoo.com"

  @required_meta_fields ~w(
    regularMarketTime
    regularMarketOpen
    regularMarketDayHigh
    regularMarketDayLow
    regularMarketPrice
    regularMarketVolume
  )

  @impl Vigil.Adapters.Provider
  def fetch(%Asset{} = asset), do: fetch(asset, [])

  @doc """
  Fetches a quote for `asset`. Accepts extra `req_opts` for testing (e.g.
  `plug: {Req.Test, name}`).
  """
  @spec fetch(Asset.t(), keyword()) :: {:ok, MarketSnapshot.t()} | {:error, Error.t()}
  def fetch(%Asset{symbol: symbol}, req_opts) when is_binary(symbol) do
    symbol
    |> build_request(req_opts)
    |> Req.get()
    |> handle_response(symbol)
  end

  defp build_request(symbol, req_opts) do
    config = Application.get_env(:vigil, Vigil.Adapters.Provider, [])

    [
      base_url: @base_url,
      url: "/v8/finance/chart/#{URI.encode(symbol, &URI.char_unreserved?/1)}",
      params: [interval: "1d", range: "1d"],
      receive_timeout: Keyword.get(config, :timeout, 10_000),
      retry: false,
      headers: [{"user-agent", user_agent()}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.merge(req_opts)
    |> Req.new()
  end

  defp handle_response({:ok, %{status: 200, body: body}}, symbol) do
    normalize_body(body, symbol)
  end

  defp handle_response({:ok, %{status: 401}}, symbol),
    do: error(:authentication, "yahoo authentication failed", symbol, %{status: 401})

  defp handle_response({:ok, %{status: 403}}, symbol),
    do: error(:authentication, "yahoo authentication failed", symbol, %{status: 403})

  defp handle_response({:ok, %{status: 429, body: body}}, symbol) do
    error(:rate_limit, "yahoo rate limit exceeded", symbol, %{status: 429, body: truncate(body)})
  end

  defp handle_response({:ok, %{status: status}}, symbol) when status >= 500 do
    error(:unavailable, "yahoo service unavailable", symbol, %{status: status})
  end

  defp handle_response({:ok, %{status: 404}}, symbol) do
    error(:invalid_response, "yahoo symbol not found", symbol, %{status: 404})
  end

  defp handle_response({:ok, %{status: status, body: body}}, symbol) do
    error(:invalid_response, "unexpected yahoo response", symbol, %{
      status: status,
      body: truncate(body)
    })
  end

  defp handle_response({:error, reason}, symbol) do
    classify_request_error(reason, symbol)
  end

  defp normalize_body(%{"chart" => chart}, symbol) when is_map(chart) do
    case chart["error"] do
      %{"code" => code} = err ->
        error(:invalid_response, Map.get(err, "description") || "yahoo chart error", symbol, %{
          code: code
        })

      _ ->
        case chart["result"] do
          [%{"meta" => meta} | _] -> build_snapshot(symbol, meta)
          _ -> error(:invalid_response, "yahoo response has no chart result", symbol)
        end
    end
  end

  defp normalize_body(_body, symbol) do
    error(:invalid_response, "unexpected yahoo response shape", symbol)
  end

  defp build_snapshot(symbol, meta) do
    with :ok <- validate_meta(meta, symbol),
         {:ok, timestamp} <- parse_timestamp(meta["regularMarketTime"], symbol),
         {:ok, open} <- parse_float(meta["regularMarketOpen"], "open", symbol),
         {:ok, high} <- parse_float(meta["regularMarketDayHigh"], "high", symbol),
         {:ok, low} <- parse_float(meta["regularMarketDayLow"], "low", symbol),
         {:ok, price} <- parse_float(meta["regularMarketPrice"], "price", symbol),
         {:ok, close} <- parse_close(meta, price, symbol),
         {:ok, volume} <- parse_volume(meta["regularMarketVolume"], symbol) do
      {:ok,
       %MarketSnapshot{
         symbol: symbol,
         timestamp: timestamp,
         open: open,
         high: high,
         low: low,
         close: close,
         price: price,
         volume: volume,
         market_open: parse_market_open(meta)
       }}
    end
  end

  defp validate_meta(meta, symbol) when is_map(meta) do
    missing =
      Enum.filter(@required_meta_fields, fn field ->
        is_nil(Map.get(meta, field))
      end)

    if missing == [] do
      :ok
    else
      error(:invalid_response, "yahoo response missing required fields", symbol, %{
        missing: missing
      })
    end
  end

  defp validate_meta(_meta, symbol) do
    error(:invalid_response, "yahoo meta is not a map", symbol)
  end

  defp parse_timestamp(value, _symbol) when is_integer(value) and value > 0 do
    {:ok, DateTime.from_unix!(value, :second)}
  end

  defp parse_timestamp(value, symbol) do
    error(:invalid_response, "invalid regularMarketTime", symbol, %{value: value})
  end

  defp parse_float(value, _field, _symbol) when is_number(value), do: {:ok, value * 1.0}

  defp parse_float(value, field, symbol),
    do: error(:invalid_response, "invalid #{field}", symbol, %{field: field, value: value})

  defp parse_close(meta, price, symbol) do
    case meta["chartPreviousClose"] || meta["previousClose"] do
      nil -> {:ok, price}
      value -> parse_float(value, "close", symbol)
    end
  end

  defp parse_volume(value, _symbol) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp parse_volume(value, _symbol) when is_float(value) and value >= 0 do
    {:ok, trunc(value)}
  end

  defp parse_volume(value, symbol) do
    error(:invalid_response, "invalid regularMarketVolume", symbol, %{value: value})
  end

  # Yahoo marketState: REGULAR is the only open session; PRE/POST/CLOSED etc.
  # are treated as closed. Absent field defaults to open (RFC-0015 DEC-010).
  defp parse_market_open(%{"marketState" => state}) when is_binary(state),
    do: state == "REGULAR"

  defp parse_market_open(_meta), do: true

  defp classify_request_error(%Req.TransportError{reason: :timeout}, symbol) do
    error(:timeout, "yahoo request timed out", symbol)
  end

  defp classify_request_error(%Req.TransportError{reason: reason}, symbol) do
    error(:network, "yahoo network error", symbol, %{reason: reason})
  end

  defp classify_request_error(%Jason.DecodeError{} = reason, symbol) do
    error(:invalid_response, "yahoo response is not valid JSON", symbol, %{reason: reason})
  end

  defp classify_request_error(reason, symbol) do
    error(:invalid_response, "yahoo request failed", symbol, %{reason: reason})
  end

  defp error(category, message, symbol, details \\ %{}) do
    {:error,
     Error.new(category, %{
       message: message,
       provider: @provider,
       symbol: symbol,
       details: details
     })}
  end

  defp user_agent do
    "Vigil/#{Application.spec(:vigil, :vsn)} (financial monitoring)"
  end

  defp truncate(body) when is_binary(body) do
    if String.length(body) > 200, do: String.slice(body, 0, 200) <> "...", else: body
  end

  defp truncate(body), do: body
end
