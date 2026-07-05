defmodule Vigil.Adapters.Provider.RegistryMergeTest do
  # async: false because it mutates the global `:vigil, :providers` env.
  use ExUnit.Case, async: false

  alias Vigil.Adapters.Provider.{Registry, Yahoo}

  defmodule MockProvider do
    @moduledoc false
  end

  setup do
    previous = Application.get_env(:vigil, :providers)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:vigil, :providers)
        value -> Application.put_env(:vigil, :providers, value)
      end
    end)

    Application.put_env(:vigil, :providers, %{"mock" => MockProvider})

    :ok
  end

  test "override merges over built-in providers instead of replacing them" do
    assert {:ok, MockProvider} = Registry.fetch("mock")
    assert {:ok, Yahoo} = Registry.fetch("yahoo")
  end

  test "built-in provider is still listed when an override is set" do
    assert "yahoo" in Registry.all()
    assert "mock" in Registry.all()
  end
end
