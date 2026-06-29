defmodule Vigil.Core.RuleEngineRunTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Context
  alias Vigil.Core.MarketSnapshot
  alias Vigil.Core.Rule
  alias Vigil.Core.RuleEngine

  defp context(overrides \\ []) do
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

    MarketSnapshot
    |> struct!(Keyword.merge(defaults, overrides))
    |> Context.build(asset: "petr4", provider: "yahoo")
  end

  defp rule(name, condition, opts \\ []) do
    %Rule{
      name: name,
      asset: Keyword.get(opts, :asset, "petr4"),
      condition: condition,
      actions: Keyword.get(opts, :actions, [:telegram])
    }
  end

  describe "run/3" do
    test "returns the rules that fire for the context's asset" do
      rules = [
        rule("breakout", %{field: :price, op: :gt, value: 40}),
        rule("moonshot", %{field: :price, op: :gt, value: 999})
      ]

      assert {:ok, [%Rule{name: "breakout"}]} = RuleEngine.run(rules, context(price: 41.0))
    end

    test "ignores rules targeting a different asset" do
      rules = [rule("vale", %{field: :price, op: :gt, value: 1}, asset: "vale3")]

      assert {:ok, []} = RuleEngine.run(rules, context(price: 41.0))
    end

    test "preserves the order of fired rules" do
      rules = [
        rule("a", %{field: :price, op: :gt, value: 1}),
        rule("b", %{field: :volume, op: :gt, value: 1})
      ]

      assert {:ok, [%Rule{name: "a"}, %Rule{name: "b"}]} =
               RuleEngine.run(rules, context(price: 41.0))
    end

    test "returns an empty list when nothing fires" do
      rules = [rule("quiet", %{field: :price, op: :gt, value: 999})]

      assert {:ok, []} = RuleEngine.run(rules, context(price: 41.0))
    end

    test "surfaces an evaluation error with the rule name" do
      rules = [rule("bad", %{field: :bogus, op: :gt, value: 1})]

      assert {:error, {:rule, "bad", {:unknown_field, :bogus}}} =
               RuleEngine.run(rules, context())
    end

    test "passes the previous context through for crossings" do
      rules = [rule("cross", %{field: :price, op: :crossed_above, value: 40})]

      assert {:ok, [%Rule{name: "cross"}]} =
               RuleEngine.run(rules, context(price: 41.0), previous: context(price: 39.0))
    end
  end
end
