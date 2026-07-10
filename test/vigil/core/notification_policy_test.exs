defmodule Vigil.Core.NotificationPolicyTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.NotificationPolicy
  alias Vigil.Core.State.{NotificationStatus, RuleStatus}

  @now ~U[2026-07-01 10:30:00Z]

  defp input(overrides) do
    Map.merge(
      %{satisfied: true, previous: nil, notification: nil, cooldown: "5m", now: @now},
      Map.new(overrides)
    )
  end

  describe "decide/1" do
    test "not satisfied → :none" do
      assert NotificationPolicy.decide(input(satisfied: false)) == :none
    end

    test "first cycle satisfied (no previous status) → :notify" do
      assert NotificationPolicy.decide(input(previous: nil)) == :notify
    end

    test "transition into satisfied → :notify" do
      assert NotificationPolicy.decide(input(previous: %RuleStatus{satisfied: false})) == :notify
    end

    test "still satisfied → suppress (RFC-0007 §9 V1 default)" do
      assert NotificationPolicy.decide(input(previous: %RuleStatus{satisfied: true})) ==
               {:suppress, :still_satisfied}
    end

    test "re-transition inside the cooldown window → suppress" do
      notification = %NotificationStatus{last_notified_at: DateTime.add(@now, -60, :second)}

      assert NotificationPolicy.decide(
               input(previous: %RuleStatus{satisfied: false}, notification: notification)
             ) == {:suppress, :cooldown}
    end

    test "re-transition after the cooldown window → :notify" do
      notification = %NotificationStatus{last_notified_at: DateTime.add(@now, -301, :second)}

      assert NotificationPolicy.decide(
               input(previous: %RuleStatus{satisfied: false}, notification: notification)
             ) == :notify
    end

    test "notification status without a timestamp does not block" do
      notification = %NotificationStatus{last_notified_at: nil}

      assert NotificationPolicy.decide(
               input(previous: %RuleStatus{satisfied: false}, notification: notification)
             ) == :notify
    end
  end
end
