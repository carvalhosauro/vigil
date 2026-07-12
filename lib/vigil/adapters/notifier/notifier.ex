defmodule Vigil.Adapters.Notifier do
  @moduledoc """
  Notification delivery behaviour (RFC-0007 §6, RFC-0014).

  A Notifier receives the rule that fired, the Context it fired against and
  the channel configuration resolved for the action (e.g. the `Telegram`
  resource from RFC-0003), renders a message and delivers it. It never
  evaluates rules and never decides whether to notify — that is
  `Vigil.Core.NotificationPolicy`, applied by the Runtime before dispatch
  (RFC-0015 §12).

  Channel configuration is passed explicitly so notifiers stay stateless;
  notifiers that need no configuration (e.g. the log notifier) ignore it.
  """

  alias Vigil.Core.Config.Rule
  alias Vigil.Core.Context

  @callback notify(rule :: Rule.t(), context :: Context.t(), channel_config :: term()) ::
              {:ok, delivery :: map()} | {:error, term()}
end
