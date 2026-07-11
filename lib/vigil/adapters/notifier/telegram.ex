defmodule Vigil.Adapters.Notifier.Telegram do
  @moduledoc """
  Telegram Notifier (V1's only delivery channel — RFC-0007 §8).

  Renders the shared default template (`Vigil.Adapters.Notifier.Message`) and
  posts it to the Telegram Bot API `sendMessage` endpoint as plain text (no
  `parse_mode`).

  `token` and `chat_id` on `Vigil.Core.Config.Telegram` are unexpanded
  `${ENV_VAR}` strings (RFC-0003 §5.3); they are expanded from the environment
  at delivery time, never at config-load time, so credentials are never held
  outside the process performing the request.

  The bot token is part of the request URL path. It must never appear in a
  log line, an error message, or an error's `details` — only the resolved
  environment variable *name* is ever surfaced, on the `:configuration`
  error path.
  """

  @behaviour Vigil.Adapters.Notifier

  alias Vigil.Adapters.Notifier.Error
  alias Vigil.Adapters.Notifier.Message
  alias Vigil.Core.Config
  alias Vigil.Core.Config.Rule
  alias Vigil.Core.Context

  @notifier "telegram"
  @base_url "https://api.telegram.org"
  @env_var_pattern ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/

  @impl Vigil.Adapters.Notifier
  def notify(%Rule{} = rule, %Context{} = context, %Config.Telegram{} = channel_config),
    do: notify(rule, context, channel_config, [])

  @doc """
  Delivers `rule`/`context` to Telegram. Accepts extra `req_opts` for testing
  (e.g. `plug: {Req.Test, name}`).
  """
  @spec notify(Rule.t(), Context.t(), Config.Telegram.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def notify(%Rule{} = rule, %Context{} = context, %Config.Telegram{} = channel_config, req_opts) do
    with {:ok, token} <- expand_env(channel_config.token, "token"),
         {:ok, chat_id} <- expand_env(channel_config.chat_id, "chat_id") do
      text = Message.render(rule, context)

      token
      |> build_request(chat_id, text, req_opts)
      |> Req.post()
      |> handle_response()
    end
  end

  defp build_request(token, chat_id, text, req_opts) do
    config = Application.get_env(:vigil, Vigil.Adapters.Notifier, [])

    [
      base_url: Keyword.get(config, :base_url, @base_url),
      url: "/bot#{token}/sendMessage",
      json: %{chat_id: chat_id, text: text},
      receive_timeout: Keyword.get(config, :timeout, 10_000),
      retry: false
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.merge(req_opts)
    |> Req.new()
  end

  defp handle_response(
         {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"message_id" => id}}}}
       ) do
    {:ok, %{channel: "telegram", message_id: id}}
  end

  defp handle_response({:ok, %{status: status}}) when status in [401, 404] do
    error(:authentication, "telegram authentication failed", %{status: status})
  end

  defp handle_response({:ok, %{status: 400, body: body}}) do
    error(
      :invalid_target,
      target_message(body, "telegram chat not found"),
      error_details(400, body)
    )
  end

  defp handle_response({:ok, %{status: 403, body: body}}) do
    error(
      :invalid_target,
      target_message(body, "telegram bot blocked or kicked"),
      error_details(403, body)
    )
  end

  defp handle_response({:ok, %{status: 429, body: body}}) do
    error(
      :rate_limit,
      target_message(body, "telegram rate limit exceeded"),
      error_details(429, body) |> put_retry_after(body)
    )
  end

  defp handle_response({:ok, %{status: status}}) when status >= 500 do
    error(:unavailable, "telegram service unavailable", %{status: status})
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    error(:invalid_response, "unexpected telegram response", error_details(status, body))
  end

  defp handle_response({:error, reason}) do
    classify_request_error(reason)
  end

  defp target_message(%{"description" => desc}, _default) when is_binary(desc), do: desc
  defp target_message(_body, default), do: default

  defp error_details(status, %{"description" => desc}) when is_binary(desc) do
    %{status: status, description: truncate(desc)}
  end

  defp error_details(status, _body), do: %{status: status}

  defp put_retry_after(details, %{"parameters" => %{"retry_after" => retry_after}})
       when is_number(retry_after) do
    Map.put(details, :retry_after_ms, retry_after * 1000)
  end

  defp put_retry_after(details, _body), do: details

  defp classify_request_error(%Req.TransportError{reason: :timeout}) do
    error(:timeout, "telegram request timed out")
  end

  defp classify_request_error(%Req.TransportError{reason: reason}) do
    error(:network, "telegram network error", %{reason: reason})
  end

  defp classify_request_error(%Jason.DecodeError{} = reason) do
    error(:invalid_response, "telegram response is not valid JSON", %{reason: reason})
  end

  defp classify_request_error(reason) do
    error(:invalid_response, "telegram request failed", %{reason: reason})
  end

  defp expand_env(value, field) do
    @env_var_pattern
    |> Regex.scan(value, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, value}, fn var, {:ok, acc} ->
      case System.fetch_env(var) do
        {:ok, resolved} -> {:cont, {:ok, String.replace(acc, "${#{var}}", resolved)}}
        :error -> {:halt, {:error, var}}
      end
    end)
    |> case do
      {:ok, expanded} ->
        {:ok, expanded}

      {:error, var} ->
        error(:configuration, "telegram missing environment variable", %{
          field: field,
          env_var: var
        })
    end
  end

  defp error(category, message, details \\ %{}) do
    {:error, Error.new(category, %{message: message, notifier: @notifier, details: details})}
  end

  defp truncate(desc) when is_binary(desc) do
    if String.length(desc) > 200, do: String.slice(desc, 0, 200) <> "...", else: desc
  end
end
