defmodule Vigil.Adapters.Provider.ErrorTest do
  use ExUnit.Case, async: true

  alias Vigil.Adapters.Provider.Error

  test "builds a typed error with optional details" do
    error =
      Error.new(:timeout, %{
        message: "timed out",
        provider: "yahoo",
        symbol: "PETR4.SA",
        details: %{status: 408}
      })

    assert error.category == :timeout
    assert error.message == "timed out"
    assert error.provider == "yahoo"
    assert error.symbol == "PETR4.SA"
    assert error.details == %{status: 408}
  end

  test "accepts the :configuration category (RFC-0013 §5 / RFC-0014 §11)" do
    error =
      Error.new(:configuration, %{
        message: "unresolved provider name",
        provider: "vigil",
        symbol: "n/a"
      })

    assert error.category == :configuration
    assert error.details == %{}
  end

  test "rejects an unknown category" do
    assert_raise FunctionClauseError, fn ->
      Error.new(:bogus, %{message: "x", provider: "yahoo", symbol: "PETR4.SA"})
    end
  end
end
