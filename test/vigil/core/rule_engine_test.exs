defmodule Vigil.Core.RuleEngineTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Context
  alias Vigil.Core.MarketSnapshot
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

  describe "comparison operators" do
    test "gt is true when the field exceeds the value" do
      assert RuleEngine.evaluate(%{field: :price, op: :gt, value: 40}, context(price: 41.0)) ==
               {:ok, true}
    end

    test "gt is false when the field is below the value" do
      assert RuleEngine.evaluate(%{field: :price, op: :gt, value: 40}, context(price: 39.0)) ==
               {:ok, false}
    end

    test "gte is true at the boundary" do
      assert RuleEngine.evaluate(%{field: :price, op: :gte, value: 40}, context(price: 40.0)) ==
               {:ok, true}
    end

    test "lt / lte / eq / ne" do
      assert {:ok, true} =
               RuleEngine.evaluate(%{field: :volume, op: :lt, value: 1_000}, context(volume: 999))

      assert {:ok, true} =
               RuleEngine.evaluate(%{field: :volume, op: :lte, value: 999}, context(volume: 999))

      assert {:ok, true} =
               RuleEngine.evaluate(%{field: :volume, op: :eq, value: 999}, context(volume: 999))

      assert {:ok, true} =
               RuleEngine.evaluate(%{field: :volume, op: :ne, value: 1}, context(volume: 999))
    end
  end

  describe "field resolution" do
    test "resolves market fields" do
      assert {:ok, true} = RuleEngine.evaluate(%{field: :high, op: :gt, value: 38.0}, context())
    end

    test "resolves derived fields" do
      assert {:ok, true} =
               RuleEngine.evaluate(%{field: :change_percent, op: :gt, value: 0}, context())
    end

    test "resolves consecutive_failures from runtime" do
      ctx = context() |> then(&%{&1 | runtime: %{consecutive_failures: 3}})

      assert {:ok, true} =
               RuleEngine.evaluate(%{field: :consecutive_failures, op: :gte, value: 3}, ctx)
    end

    test "a nil-valued field does not fire (no false positive)" do
      assert {:ok, false} =
               RuleEngine.evaluate(%{field: :volume_delta, op: :gt, value: 0}, context())
    end
  end

  describe "errors" do
    test "unknown field is a config error" do
      assert {:error, {:unknown_field, :pricee}} =
               RuleEngine.evaluate(%{field: :pricee, op: :gt, value: 1}, context())
    end

    test "unsupported operator is a config error" do
      assert {:error, {:unsupported_operator, :neq}} =
               RuleEngine.evaluate(%{field: :price, op: :neq, value: 1}, context())
    end
  end

  describe "logical operators" do
    test "all is true only when every condition holds" do
      cond = %{
        all: [%{field: :price, op: :gt, value: 40}, %{field: :volume, op: :gt, value: 100}]
      }

      assert {:ok, true} = RuleEngine.evaluate(cond, context(price: 41.0, volume: 200))
      assert {:ok, false} = RuleEngine.evaluate(cond, context(price: 41.0, volume: 50))
    end

    test "any is true when at least one holds" do
      cond = %{
        any: [%{field: :price, op: :gt, value: 100}, %{field: :volume, op: :gt, value: 100}]
      }

      assert {:ok, true} = RuleEngine.evaluate(cond, context(price: 41.0, volume: 200))
      assert {:ok, false} = RuleEngine.evaluate(cond, context(price: 41.0, volume: 50))
    end

    test "not negates the inner condition" do
      cond = %{not: %{field: :price, op: :gt, value: 40}}

      assert {:ok, false} = RuleEngine.evaluate(cond, context(price: 41.0))
      assert {:ok, true} = RuleEngine.evaluate(cond, context(price: 39.0))
    end

    test "nested logical conditions" do
      cond = %{
        all: [
          %{
            any: [%{field: :price, op: :gt, value: 40}, %{field: :volume, op: :gt, value: 9_999}]
          },
          %{not: %{field: :market_open, op: :eq, value: false}}
        ]
      }

      assert {:ok, true} = RuleEngine.evaluate(cond, context(price: 41.0))
    end

    test "an error in a sub-condition propagates" do
      cond = %{all: [%{field: :price, op: :gt, value: 40}, %{field: :bogus, op: :gt, value: 1}]}

      assert {:error, {:unknown_field, :bogus}} =
               RuleEngine.evaluate(cond, context(price: 41.0))
    end
  end

  describe "crossings" do
    test "crossed_above fires when previous <= value and current > value" do
      assert {:ok, true} =
               RuleEngine.evaluate(
                 %{field: :price, op: :crossed_above, value: 40},
                 context(price: 41.0),
                 previous: context(price: 39.0)
               )
    end

    test "crossed_above does not fire when already above the value" do
      assert {:ok, false} =
               RuleEngine.evaluate(
                 %{field: :price, op: :crossed_above, value: 40},
                 context(price: 42.0),
                 previous: context(price: 41.0)
               )
    end

    test "crossed_below fires when previous >= value and current < value" do
      assert {:ok, true} =
               RuleEngine.evaluate(
                 %{field: :price, op: :crossed_below, value: 40},
                 context(price: 39.0),
                 previous: context(price: 41.0)
               )
    end

    test "a crossing never fires without a previous value" do
      assert {:ok, false} =
               RuleEngine.evaluate(
                 %{field: :price, op: :crossed_above, value: 40},
                 context(price: 41.0)
               )
    end

    test "a crossing does not fire when the field value is unavailable" do
      assert {:ok, false} =
               RuleEngine.evaluate(
                 %{field: :volume_delta, op: :crossed_above, value: 0},
                 context(),
                 previous: context()
               )
    end
  end
end
