defmodule Vigil.Adapters.Provider.Yahoo do
  @moduledoc """
  Yahoo Finance market data provider (v1).

  Uses the public chart API (`/v8/finance/chart/{symbol}`). Data may be delayed
  and the endpoint is unofficial — no SLA guarantees (see ROADMAP).

  Snapshot semantics for a point-in-time poll:

    * `price` and `close` both map to `regularMarketPrice` (last known price).
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
      url: "/v8/finance/chart/#{URI.encode(symbol)}",
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
    do: auth_error(symbol, 401)

  defp handle_response({:ok, %{status: 403}}, symbol),
    do: auth_error(symbol, 403)

  defp handle_response({:ok, %{status: 429, body: body}}, symbol),
    do:
      {:error,
       Error.new(:rate_limit, %{
         message: "yahoo rate limit exceeded",
         provider: @provider,
         symbol: symbol,
         details: %{status: 429, body: truncate(body)}
       })}

  defp handle_response({:ok, %{status: status}}, symbol) when status >= 500 do
    {:error,
     Error.new(:unavailable, %{
       message: "yahoo service unavailable",
       provider: @provider,
       symbol: symbol,
       details: %{status: status}
     })}
  end

  defp handle_response({:ok, %{status: 404}}, symbol) do
    {:error,
     Error.new(:invalid_response, %{
       message: "yahoo symbol not found",
       provider: @provider,
       symbol: symbol,
       details: %{status: 404}
     })}
  end

  defp handle_response({:ok, %{status: status, body: body}}, symbol) do
    {:error,
     Error.new(:invalid_response, %{
       message: "unexpected yahoo response",
       provider: @provider,
       symbol: symbol,
       details: %{status: status, body: truncate(body)}
     })}
  end

  defp handle_response({:error, reason}, symbol) do
    {:error, classify_request_error(reason, symbol)}
  end

  defp normalize_body(body, symbol) when is_map(body) do
    case get_in(body, ["chart", "error"]) do
      %{"code" => code, "description" => description} ->
        category =
          if code in ["Not Found", "Not Found - symbol may be delisted"] do
            :invalid_response
          else
            :unavailable
          end

        {:error,
         Error.new(category, %{
           message: description || "yahoo chart error",
           provider: @provider,
           symbol: symbol,
           details: %{code: code}
         })}

      _ ->
        case get_in(body, ["chart", "result"]) do
          [%{"meta" => meta} | _] -> build_snapshot(symbol, meta)
          _ -> missing_result_error(symbol)
        end
    end
  end

  defp normalize_body(_body, symbol) do
    {:error,
     Error.new(:invalid_response, %{
       message: "yahoo response is not a JSON object",
       provider: @provider,
       symbol: symbol
     })}
  end

  defp build_snapshot(symbol, meta) do
    with :ok <- validate_meta(meta, symbol),
         {:ok, timestamp} <- parse_timestamp(meta["regularMarketTime"], symbol),
         {:ok, open} <- parse_float(meta["regularMarketOpen"], "open", symbol),
         {:ok, high} <- parse_float(meta["regularMarketDayHigh"], "high", symbol),
         {:ok, low} <- parse_float(meta["regularMarketDayLow"], "low", symbol),
         {:ok, price} <- parse_float(meta["regularMarketPrice"], "price", symbol),
         {:ok, volume} <- parse_volume(meta["regularMarketVolume"], symbol) do
      {:ok,
       %MarketSnapshot{
         symbol: symbol,
         timestamp: timestamp,
         open: open,
         high: high,
         low: low,
         close: price,
         price: price,
         volume: volume
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
      {:error,
       Error.new(:invalid_response, %{
         message: "yahoo response missing required fields",
         provider: @provider,
         symbol: symbol,
         details: %{missing: missing}
       })}
    end
  end

  defp validate_meta(_meta, symbol) do
    {:error,
     Error.new(:invalid_response, %{
       message: "yahoo meta is not a map",
       provider: @provider,
       symbol: symbol
     })}
  end

  defp parse_timestamp(value, _symbol) when is_integer(value) and value > 0 do
    {:ok, DateTime.from_unix!(value, :second)}
  end

  defp parse_timestamp(value, symbol) do
    {:error,
     Error.new(:invalid_response, %{
       message: "invalid regularMarketTime",
       provider: @provider,
       symbol: symbol,
       details: %{value: value}
     })}
  end

  defp parse_float(value, field, symbol) when is_number(value) do
    if is_float(value) and is_nan(value) do
      invalid_number_error(field, value, symbol)
    else
      {:ok, value * 1.0}
    end
  end

  defp parse_float(value, field, symbol) do
    invalid_number_error(field, value, symbol)
  end

  defp parse_volume(value, _symbol) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp parse_volume(value, _symbol) when is_float(value) and value >= 0 do
    {:ok, trunc(value)}
  end

  defp parse_volume(value, symbol) do
    {:error,
     Error.new(:invalid_response, %{
       message: "invalid regularMarketVolume",
       provider: @provider,
       symbol: symbol,
       details: %{value: value}
     })}
  end

  defp classify_request_error(%Req.TransportError{reason: :timeout}, symbol) do
    Error.new(:timeout, %{
      message: "yahoo request timed out",
      provider: @provider,
      symbol: symbol
    })
  end

  defp classify_request_error(%Req.TransportError{reason: reason}, symbol) do
    Error.new(:network, %{
      message: "yahoo network error",
      provider: @provider,
      symbol: symbol,
      details: %{reason: reason}
    })
  end

  defp classify_request_error(%Jason.DecodeError{} = reason, symbol) do
    Error.new(:invalid_response, %{
      message: "yahoo response is not valid JSON",
      provider: @provider,
      symbol: symbol,
      details: %{reason: reason}
    })
  end

  defp classify_request_error(reason, symbol) do
    Error.new(:network, %{
      message: "yahoo request failed",
      provider: @provider,
      symbol: symbol,
      details: %{reason: reason}
    })
  end

  defp auth_error(symbol, status) do
    {:error,
     Error.new(:authentication, %{
       message: "yahoo authentication failed",
       provider: @provider,
       symbol: symbol,
       details: %{status: status}
     })}
  end

  defp missing_result_error(symbol) do
    {:error,
     Error.new(:invalid_response, %{
       message: "yahoo response has no chart result",
       provider: @provider,
       symbol: symbol
     })}
  end

  defp invalid_number_error(field, value, symbol) do
    {:error,
     Error.new(:invalid_response, %{
       message: "invalid #{field}",
       provider: @provider,
       symbol: symbol,
       details: %{field: field, value: value}
     })}
  end

  defp user_agent do
    "Vigil/#{Application.spec(:vigil, :vsn)} (financial monitoring)"
  end

  defp truncate(body) when is_binary(body) do
    if String.length(body) > 200, do: String.slice(body, 0, 200) <> "...", else: body
  end

  defp truncate(body), do: body

  defp is_nan(value) when is_float(value), do: value != value
  defp is_nan(_), do: false
end
