defmodule Vigil.Adapters.Notifier.RegistryTest do
  use ExUnit.Case, async: false

  alias Vigil.Adapters.Notifier.Registry

  defmodule SomeModule do
    @moduledoc false
  end

  test "telegram resolves to the log notifier until the real one lands" do
    assert Registry.fetch("telegram") == {:ok, Vigil.Adapters.Notifier.Log}
  end

  test "unknown names return :error" do
    assert Registry.fetch("smoke-signal") == :error
  end

  test "app env overrides merge over the built-in map" do
    Application.put_env(:vigil, :notifiers, %{"custom" => SomeModule})
    on_exit(fn -> Application.delete_env(:vigil, :notifiers) end)

    assert Registry.fetch("custom") == {:ok, SomeModule}
    assert Registry.fetch("telegram") == {:ok, Vigil.Adapters.Notifier.Log}
  end
end
