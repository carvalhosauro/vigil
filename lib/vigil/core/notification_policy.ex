defmodule Vigil.Core.NotificationPolicy do
  @moduledoc """
  Decides whether a rule result becomes a notification.

  Pure dedup/cooldown policy (RFC-0007 §9, RFC-0015 §12): V1 notifies on the
  transition into the satisfied state, suppresses while it stays satisfied, and
  enforces the per-rule cooldown between repeated alerts. The Runtime calls this
  before dispatching; Notifiers never decide whether a rule fired.
  """

  alias Vigil.Core.Duration
  alias Vigil.Core.State.{NotificationStatus, RuleStatus}

  @type decision :: :notify | {:suppress, :still_satisfied | :cooldown} | :none

  @type input :: %{
          satisfied: boolean(),
          previous: RuleStatus.t() | nil,
          notification: NotificationStatus.t() | nil,
          cooldown: String.t(),
          now: DateTime.t()
        }

  @spec decide(input()) :: decision()
  def decide(%{satisfied: false}), do: :none

  def decide(%{satisfied: true, previous: %RuleStatus{satisfied: true}}),
    do: {:suppress, :still_satisfied}

  def decide(%{satisfied: true} = input) do
    if in_cooldown?(input.notification, input.cooldown, input.now) do
      {:suppress, :cooldown}
    else
      :notify
    end
  end

  defp in_cooldown?(nil, _cooldown, _now), do: false
  defp in_cooldown?(%NotificationStatus{last_notified_at: nil}, _cooldown, _now), do: false

  defp in_cooldown?(%NotificationStatus{last_notified_at: last}, cooldown, now) do
    {:ok, cooldown_ms} = Duration.to_ms(cooldown)
    DateTime.diff(now, last, :millisecond) < cooldown_ms
  end
end
