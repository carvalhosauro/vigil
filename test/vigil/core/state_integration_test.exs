defmodule Vigil.Core.StateIntegrationTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Context
  alias Vigil.Core.MarketSnapshot
  alias Vigil.Core.Rule
  alias Vigil.Core.RuleEngine
  alias Vigil.Core.State

  defp snapshot(overrides) do
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

  defp cycle_input(snapshot, overrides \\ []) do
    defaults = [
      snapshot: snapshot,
      asset: "petr4",
      provider: "yahoo",
      market_open: true,
      provider_online: true
    ]

    Map.merge(Map.new(defaults), Map.new(overrides))
  end

  defp run_cycle(state, snapshot, rules) do
    prep = State.prepare_cycle(state, cycle_input(snapshot))
    context = Context.build(snapshot, prep.context_opts)

    {:ok, fired} =
      RuleEngine.run(rules, context, previous: prep.previous_context)

    {context, fired, prep.previous_context}
  end

  test "price crossing fires on second cycle through state wiring" do
    state = State.initial()
    first = snapshot(price: 39.0, timestamp: ~U[2026-07-01 10:00:00Z])
    second = snapshot(price: 41.0, timestamp: ~U[2026-07-01 10:30:00Z])

    rule = %Rule{
      name: "cross-40",
      asset: "petr4",
      condition: %{field: :price, op: :crossed_above, value: 40},
      actions: [:telegram]
    }

    {_ctx, fired, _prev} = run_cycle(state, first, [rule])
    assert fired == []

    state =
      State.advance(state, %{
        snapshot: first,
        fetch_outcome: :ok,
        rule_results: %{"cross-40" => false},
        runtime: %{
          market_open: true,
          provider_online: true,
          last_update: nil,
          consecutive_failures: 0
        }
      })

    {_ctx, fired, previous} = run_cycle(state, second, [rule])

    assert previous.market.price == 39.0
    assert fired == [rule]
  end

  test "volume_delta crossing fires when wired through state" do
    state = State.initial()
    first = snapshot(volume: 100, timestamp: ~U[2026-07-01 10:00:00Z])
    second = snapshot(volume: 130, timestamp: ~U[2026-07-01 10:15:00Z])
    third = snapshot(volume: 200, timestamp: ~U[2026-07-01 10:30:00Z])

    rule = %Rule{
      name: "vol-delta",
      asset: "petr4",
      condition: %{field: :volume_delta, op: :crossed_above, value: 50},
      actions: [:telegram]
    }

    rt = %{market_open: true, provider_online: true, last_update: nil, consecutive_failures: 0}

    run_cycle(state, first, [rule])

    state =
      State.advance(state, %{snapshot: first, fetch_outcome: :ok, rule_results: %{}, runtime: rt})

    run_cycle(state, second, [rule])

    state =
      State.advance(state, %{
        snapshot: second,
        fetch_outcome: :ok,
        rule_results: %{},
        runtime: rt
      })

    {ctx, fired, _} = run_cycle(state, third, [rule])

    assert ctx.derived.volume_delta == 70
    assert fired == [rule]
  end
end
