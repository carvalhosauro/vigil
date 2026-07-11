defmodule Vigil.Runtime.CycleTest do
  use ExUnit.Case, async: true

  alias Vigil.Adapters.Provider.Error
  alias Vigil.Core.Config.{Asset, Rule}
  alias Vigil.Core.{MarketSnapshot, State}
  alias Vigil.Runtime.{Cycle, CycleReport}

  defp asset, do: %Asset{name: "petr4", symbol: "PETR4.SA", provider: "yahoo", interval: "30s"}

  defp rule(overrides \\ []) do
    struct!(
      %Rule{
        name: "breakout",
        asset: "petr4",
        condition: %{field: :price, op: :gt, value: 40},
        actions: ["telegram"],
        cooldown: "5m"
      },
      overrides
    )
  end

  defp snapshot(price) do
    struct!(MarketSnapshot,
      symbol: "PETR4.SA",
      timestamp: ~U[2026-07-01 10:30:00Z],
      open: 39.0,
      high: 41.0,
      low: 38.5,
      close: 39.0,
      price: price,
      volume: 1_000
    )
  end

  defp run(overrides) do
    input =
      Map.merge(
        %{
          asset: asset(),
          rules: [rule()],
          state: State.initial(),
          deadline: System.monotonic_time(:millisecond) + 60_000,
          fetch: fn _asset -> {:ok, snapshot(40.12)} end,
          dispatch: fn _rule, _context -> :ok end,
          sleep_fun: fn _ms -> :ok end
        },
        Map.new(overrides)
      )

    Cycle.run(input)
  end

  describe "successful cycle" do
    test "fetches, evaluates, dispatches and advances state" do
      parent = self()

      {report, state} =
        run(dispatch: fn rule, context -> send(parent, {:dispatched, rule.name, context}) end)

      assert %CycleReport{
               outcome: :ok,
               attempts: 1,
               triggered: ["breakout"],
               notified: ["breakout"]
             } =
               report

      assert_receive {:dispatched, "breakout", context}
      assert context.market.price == 40.12
      assert state.health.consecutive_failures == 0
      assert state.previous_snapshot.price == 40.12
      assert %{last_notified_at: %DateTime{}} = state.notifications["breakout"]
    end

    test "rule not satisfied → no dispatch, rule status recorded" do
      parent = self()

      {report, state} =
        run(
          fetch: fn _ -> {:ok, snapshot(39.5)} end,
          dispatch: fn rule, _ -> send(parent, {:dispatched, rule.name}) end
        )

      assert %CycleReport{outcome: :ok, triggered: [], notified: []} = report
      refute_receive {:dispatched, _}
      assert state.rules["breakout"].satisfied == false
    end

    test "still satisfied across cycles → suppressed, single notification" do
      parent = self()
      dispatch = fn rule, _ -> send(parent, {:dispatched, rule.name}) end

      {_report, state1} = run(dispatch: dispatch)
      assert_receive {:dispatched, "breakout"}

      {report2, _state2} = run(state: state1, dispatch: dispatch)

      assert %CycleReport{notified: [], suppressed: ["breakout"]} = report2
      refute_receive {:dispatched, _}
    end
  end

  describe "retry (RFC-0015 §10)" do
    test "retries timeout errors up to 3 attempts, then fails the cycle" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      fetch = fn _asset ->
        Agent.update(agent, &(&1 + 1))
        {:error, Error.new(:timeout, %{message: "t", provider: "yahoo", symbol: "X"})}
      end

      {report, state} = run(fetch: fetch)

      assert Agent.get(agent, & &1) == 3

      assert %CycleReport{outcome: :failed, attempts: 3, error: %Error{category: :timeout}} =
               report

      assert state.health.consecutive_failures == 1
    end

    test "recovers when a retry succeeds" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      fetch = fn _asset ->
        case Agent.get_and_update(agent, &{&1, &1 + 1}) do
          0 -> {:error, Error.new(:network, %{message: "n", provider: "yahoo", symbol: "X"})}
          _ -> {:ok, snapshot(40.12)}
        end
      end

      {report, _state} = run(fetch: fetch)

      assert %CycleReport{outcome: :ok, attempts: 2, triggered: ["breakout"]} = report
    end

    test "authentication errors are never retried" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      fetch = fn _asset ->
        Agent.update(agent, &(&1 + 1))
        {:error, Error.new(:authentication, %{message: "a", provider: "yahoo", symbol: "X"})}
      end

      {report, _state} = run(fetch: fetch)

      assert Agent.get(agent, & &1) == 1
      assert %CycleReport{outcome: :failed, attempts: 1} = report
    end
  end

  describe "failed cycle (DEC-007)" do
    test "advances health, keeps previous snapshot, evaluates nothing" do
      {_report, state1} = run([])

      {report, state2} =
        run(
          state: state1,
          fetch: fn _ ->
            {:error, Error.new(:unavailable, %{message: "u", provider: "yahoo", symbol: "X"})}
          end
        )

      assert report.outcome == :failed
      assert state2.health.consecutive_failures == 1
      assert state2.previous_snapshot == state1.previous_snapshot
    end

    test "emits runtime.cycle.failed" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :failed]])

      run(
        fetch: fn _ ->
          {:error, Error.new(:timeout, %{message: "t", provider: "yahoo", symbol: "X"})}
        end
      )

      assert_receive {[:vigil, :runtime, :cycle, :failed], ^ref, _, %{asset: "petr4"}}
    end
  end

  describe "dispatch exception containment (RFC-0015 §12, DEC-003)" do
    test "raising dispatch is caught, remaining rules processed, state advances, failed event emitted" do
      parent = self()
      ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :notification, :failed]])

      rule1 = rule(name: "first")
      rule2 = rule(name: "second")

      dispatch = fn
        %{name: "first"}, _ctx -> raise "dispatch kaboom"
        %{name: "second"} = r, _ctx -> send(parent, {:dispatched, r.name})
      end

      {_report, state} =
        Cycle.run(%{
          asset: asset(),
          rules: [rule1, rule2],
          state: State.initial(),
          deadline: System.monotonic_time(:millisecond) + 60_000,
          fetch: fn _ -> {:ok, snapshot(40.12)} end,
          dispatch: dispatch,
          sleep_fun: fn _ms -> :ok end
        })

      assert_receive {:dispatched, "second"}
      assert state.health.consecutive_failures == 0
      assert state.previous_snapshot.price == 40.12

      assert_receive {[:vigil, :notification, :failed], ^ref, _, %{asset: "petr4", rule: "first"}}
    end
  end

  describe "events (DEC-009)" do
    test "emits provider.request events around the fetch" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:vigil, :provider, :request, :started],
          [:vigil, :provider, :request, :finished]
        ])

      run([])

      assert_receive {[:vigil, :provider, :request, :started], ^ref, _, %{provider: "yahoo"}}
      assert_receive {[:vigil, :provider, :request, :finished], ^ref, _, %{provider: "yahoo"}}
    end
  end
end
