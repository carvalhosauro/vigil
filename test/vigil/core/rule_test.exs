defmodule Vigil.Core.RuleTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Rule

  test "holds name, asset, condition and actions" do
    rule = %Rule{
      name: "breakout",
      asset: "petr4",
      condition: %{field: :price, op: :gt, value: 40},
      actions: [:telegram]
    }

    assert rule.name == "breakout"
    assert rule.asset == "petr4"
    assert rule.condition == %{field: :price, op: :gt, value: 40}
    assert rule.actions == [:telegram]
  end

  test "raises when a required field is missing" do
    assert_raise ArgumentError, fn -> struct!(Rule, name: "breakout") end
  end
end
