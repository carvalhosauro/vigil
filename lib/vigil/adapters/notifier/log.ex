defmodule Vigil.Adapters.Notifier.Log do
  @moduledoc """
  Log-only Notifier — this milestone's stand-in delivery channel.

  Renders the RFC-0007 §7 default template (`Vigil.Adapters.Notifier.Message`)
  and writes it to the logger. Needs no channel configuration and ignores it.
  The real Telegram notifier replaces it in the registry in a later milestone.
  """

  @behaviour Vigil.Adapters.Notifier

  require Logger

  alias Vigil.Adapters.Notifier.Message
  alias Vigil.Core.Config.Rule
  alias Vigil.Core.Context

  @impl Vigil.Adapters.Notifier
  def notify(%Rule{} = rule, %Context{} = context, _channel_config) do
    message = Message.render(rule, context)
    Logger.info(message)
    {:ok, %{channel: "log", message: message}}
  end
end
