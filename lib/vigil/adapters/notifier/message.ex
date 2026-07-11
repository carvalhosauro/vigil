defmodule Vigil.Adapters.Notifier.Message do
  @moduledoc """
  Deterministic default message template (RFC-0007 §7, DEC-004).

  Shared by all notifiers so every channel renders the same message for the
  same Rule and Context. Rendering is capped at 4096 characters — the Telegram
  `sendMessage` text limit, adopted as the global ceiling for the template.
  """

  alias Vigil.Core.Config.Rule
  alias Vigil.Core.Context

  @max_length 4096

  @spec render(Rule.t(), Context.t()) :: String.t()
  def render(%Rule{} = rule, %Context{} = context) do
    percent = :erlang.float_to_binary(context.derived.change_percent / 1, decimals: 1)
    sign = if context.derived.change_percent >= 0, do: "+", else: ""

    """
    🚨 #{context.metadata.asset} — #{rule.name}
    price: #{context.market.price}  (#{sign}#{percent}%)
    #{Calendar.strftime(context.metadata.timestamp, "%Y-%m-%d %H:%M")}
    """
    |> String.trim_trailing()
    |> truncate()
  end

  defp truncate(message) do
    if String.length(message) > @max_length,
      do: String.slice(message, 0, @max_length),
      else: message
  end
end
