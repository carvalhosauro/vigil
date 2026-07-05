defmodule Vigil.Adapters.Provider.RegistryTest do
  use ExUnit.Case, async: true

  alias Vigil.Adapters.Provider.{Registry, Yahoo}

  test "resolves built-in yahoo provider" do
    assert {:ok, Yahoo} = Registry.fetch("yahoo")
  end

  test "returns error for unknown provider" do
    assert :error = Registry.fetch("alpha")
  end

  test "lists built-in provider names" do
    assert "yahoo" in Registry.all()
  end
end
