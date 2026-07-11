defmodule Vigil.Adapters.Notifier.Log do
  @moduledoc """
  Log-only Notifier — this milestone's stand-in delivery channel.

  Renders the RFC-0007 §7 default template and writes it to the logger. The
  real Telegram notifier replaces it in the registry in a later milestone.
  """

  @behaviour Vigil.Adapters.Notifier

  require Logger

  alias Vigil.Core.Config.Rule
  alias Vigil.Core.Context

  @impl Vigil.Adapters.Notifier
  def notify(%Rule{} = rule, %Context{} = context) do
    message = render(rule, context)
    Logger.info(message)
    {:ok, %{channel: "log", message: message}}
  end

  @doc "Deterministic default template (RFC-0007 §7, DEC-004). Public for tests."
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
  end
end
