defmodule Vigil.Core.StateTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Context
  alias Vigil.Core.MarketSnapshot
  alias Vigil.Core.State
  alias Vigil.Core.State.{Health, NotificationStatus, RuleStatus}

  defp snapshot(overrides \\ []) do
    defaults = [
      symbol: "PETR4.SA",
      timestamp: ~U[2026-07-01 10:30:00Z],
      open: 37.90,
      high: 38.60,
      low: 37.80,
      close: 38.42,
      price: 38.42,
      volume: 845_231
    ]

    struct!(MarketSnapshot, Keyword.merge(defaults, overrides))
  end

  defp cycle_input(overrides \\ []) do
    defaults = [
      snapshot: snapshot(),
      asset: "petr4",
      provider: "yahoo",
      polling_interval: "30s",
      market_open: true,
      provider_online: true
    ]

    Map.merge(Map.new(defaults), Map.new(overrides))
  end

  defp runtime(overrides \\ []) do
    defaults = [
      market_open: true,
      provider_online: true,
      last_update: nil,
      consecutive_failures: 0
    ]

    Map.merge(Map.new(defaults), Map.new(overrides))
  end

  describe "initial/0" do
    test "returns empty state" do
      state = State.initial()

      assert state.previous_snapshot == nil
      assert state.prior_snapshot == nil
      assert state.previous_runtime == %{}
      assert state.health == %Health{}
      assert state.rules == %{}
      assert state.notifications == %{}
      assert state.windows == %{}
    end
  end

  describe "prepare_cycle/2" do
    test "first cycle has no previous context" do
      prep = State.prepare_cycle(State.initial(), cycle_input())

      assert prep.previous_context == nil
      assert prep.context_opts[:previous_snapshot] == nil
    end

    test "first cycle maps health into runtime" do
      prep = State.prepare_cycle(State.initial(), cycle_input())

      assert prep.context_opts[:runtime] == %{
               market_open: true,
               provider_online: true,
               last_update: nil,
               consecutive_failures: 0
             }
    end

    test "second cycle reconstructs previous context from stored snapshot and runtime" do
      first = snapshot(price: 39.0, volume: 100)
      stored_runtime = runtime(last_update: first.timestamp, consecutive_failures: 0)

      state =
        State.initial()
        |> State.advance(%{
          snapshot: first,
          fetch_outcome: :ok,
          rule_results: %{},
          runtime: stored_runtime
        })

      prep = State.prepare_cycle(state, cycle_input(snapshot: snapshot(price: 41.0)))

      assert %Context{} = prep.previous_context
      assert prep.previous_context.market.price == 39.0
      assert prep.previous_context.runtime == stored_runtime
      assert prep.context_opts[:previous_snapshot] == first
    end
  end

  describe "advance/2 on success" do
    test "shifts prior_snapshot when advancing" do
      first = snapshot(volume: 100)
      second = snapshot(volume: 200)
      rt = runtime()

      state =
        State.initial()
        |> State.advance(%{snapshot: first, fetch_outcome: :ok, rule_results: %{}, runtime: rt})
        |> State.advance(%{snapshot: second, fetch_outcome: :ok, rule_results: %{}, runtime: rt})

      assert state.prior_snapshot == first
      assert state.previous_snapshot == second
      assert state.previous_runtime == rt
    end

    test "resets consecutive_failures and sets last_success" do
      failing =
        State.advance(State.initial(), %{
          fetch_outcome: :error,
          rule_results: %{}
        })

      assert failing.health.consecutive_failures == 1

      snap = snapshot()

      state =
        State.advance(failing, %{
          snapshot: snap,
          fetch_outcome: :ok,
          rule_results: %{},
          runtime: runtime()
        })

      assert state.health.consecutive_failures == 0
      assert state.health.last_success == snap.timestamp
    end

    test "updates rule satisfaction" do
      state =
        State.advance(State.initial(), %{
          snapshot: snapshot(),
          fetch_outcome: :ok,
          rule_results: %{"price-alert" => true, "volume-alert" => false},
          runtime: runtime()
        })

      assert state.rules == %{
               "price-alert" => %RuleStatus{satisfied: true},
               "volume-alert" => %RuleStatus{satisfied: false}
             }
    end

    test "overwrites an existing rule satisfaction entry" do
      state =
        State.initial()
        |> State.advance(%{
          snapshot: snapshot(),
          fetch_outcome: :ok,
          rule_results: %{"price-alert" => true},
          runtime: runtime()
        })
        |> State.advance(%{
          snapshot: snapshot(),
          fetch_outcome: :ok,
          rule_results: %{"price-alert" => false},
          runtime: runtime()
        })

      assert state.rules["price-alert"] == %RuleStatus{satisfied: false}
    end
  end

  describe "advance/2 on failure" do
    test "increments consecutive_failures without advancing previous snapshot" do
      snap = snapshot()
      rt = runtime()

      state =
        State.initial()
        |> State.advance(%{snapshot: snap, fetch_outcome: :ok, rule_results: %{}, runtime: rt})
        |> State.advance(%{fetch_outcome: :error, rule_results: %{}})

      assert state.health.consecutive_failures == 1
      assert state.health.last_success == snap.timestamp
      assert state.previous_snapshot == snap
      assert state.previous_runtime == rt
    end
  end

  describe "read/write invariant" do
    test "context for cycle N uses previous data only before advance" do
      state = State.initial()
      first = snapshot(price: 39.0, volume: 100, timestamp: ~U[2026-07-01 10:00:00Z])
      second = snapshot(price: 41.0, volume: 150, timestamp: ~U[2026-07-01 10:30:00Z])
      rt = runtime()

      prep1 = State.prepare_cycle(state, cycle_input(snapshot: first))
      ctx1 = Context.build(first, prep1.context_opts)

      assert ctx1.derived.volume_delta == nil

      state =
        State.advance(state, %{
          snapshot: first,
          fetch_outcome: :ok,
          rule_results: %{},
          runtime: rt
        })

      prep2 = State.prepare_cycle(state, cycle_input(snapshot: second))
      ctx2 = Context.build(second, prep2.context_opts)

      assert ctx2.derived.volume_delta == 50
      assert prep2.previous_context.market.price == 39.0

      state =
        State.advance(state, %{
          snapshot: second,
          fetch_outcome: :ok,
          rule_results: %{},
          runtime: rt
        })

      assert state.previous_snapshot == second
    end
  end

  describe "record_notification/3" do
    test "updates last_notified_at for the named rule only" do
      at = ~U[2026-07-01 11:00:00Z]

      state =
        State.initial()
        |> State.record_notification("rule-a", at)
        |> State.record_notification("rule-b", ~U[2026-07-01 12:00:00Z])

      assert state.notifications["rule-a"] == %NotificationStatus{last_notified_at: at}
      assert state.notifications["rule-b"].last_notified_at == ~U[2026-07-01 12:00:00Z]
    end

    test "overwrites last_notified_at when recording again for the same rule" do
      state =
        State.initial()
        |> State.record_notification("rule-a", ~U[2026-07-01 11:00:00Z])
        |> State.record_notification("rule-a", ~U[2026-07-01 12:00:00Z])

      assert state.notifications["rule-a"].last_notified_at == ~U[2026-07-01 12:00:00Z]
    end
  end
end
