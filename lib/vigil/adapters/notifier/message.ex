defmodule Vigil.Adapters.Notifier.Message do
  @moduledoc """
  Deterministic default message template (RFC-0007 §7, DEC-004).

  Shared by all notifiers so every channel renders the same message for the
  same Rule and Context. A `nil` derived metric (RFC-0001 §12, e.g. no open
  outside trading hours) renders as `n/a` instead of raising. Rendering is
  capped at 4096 UTF-16 code units — how Telegram counts the `sendMessage`
  text limit, adopted as the global ceiling for the template.
  """

  alias Vigil.Core.Config.Rule
  alias Vigil.Core.Context

  @max_utf16_units 4096

  @spec render(Rule.t(), Context.t()) :: String.t()
  def render(%Rule{} = rule, %Context{} = context) do
    """
    🚨 #{context.metadata.asset} — #{rule.name}
    price: #{context.market.price}  (#{change_fragment(context.derived.change_percent)})
    #{Calendar.strftime(context.metadata.timestamp, "%Y-%m-%d %H:%M")}
    """
    |> String.trim_trailing()
    |> truncate()
  end

  defp change_fragment(nil), do: "n/a"

  defp change_fragment(change_percent) do
    percent = :erlang.float_to_binary(change_percent / 1, decimals: 1)
    sign = if change_percent >= 0, do: "+", else: ""
    "#{sign}#{percent}%"
  end

  # UTF-16 units never exceed UTF-8 bytes, so a small byte size is proof the
  # message fits without walking its codepoints.
  defp truncate(message) when byte_size(message) <= @max_utf16_units, do: message

  defp truncate(message) do
    {codepoints, _units} =
      message
      |> String.to_charlist()
      |> Enum.reduce_while({[], 0}, fn codepoint, {acc, units} ->
        cost = if codepoint > 0xFFFF, do: 2, else: 1

        if units + cost > @max_utf16_units,
          do: {:halt, {acc, units}},
          else: {:cont, {[codepoint | acc], units + cost}}
      end)

    codepoints |> Enum.reverse() |> List.to_string()
  end
end
