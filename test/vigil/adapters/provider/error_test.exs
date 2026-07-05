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
end
