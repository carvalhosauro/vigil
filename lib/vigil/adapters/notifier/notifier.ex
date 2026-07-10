defmodule Vigil.Adapters.Notifier do
  @moduledoc """
  Notification delivery behaviour (RFC-0007 §6, RFC-0014).

  A Notifier receives the rule that fired and the Context it fired against,
  renders a message and delivers it. It never evaluates rules and never decides
  whether to notify — that is `Vigil.Core.NotificationPolicy`, applied by the
  Runtime before dispatch (RFC-0015 §12).
  """

  alias Vigil.Core.Config.Rule
  alias Vigil.Core.Context

  @callback notify(rule :: Rule.t(), context :: Context.t()) ::
              {:ok, delivery :: map()} | {:error, term()}
end
