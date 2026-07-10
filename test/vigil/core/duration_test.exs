defmodule Vigil.Core.DurationTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Duration

  describe "to_ms/1" do
    test "parses seconds" do
      assert Duration.to_ms("15s") == {:ok, 15_000}
    end

    test "parses minutes" do
      assert Duration.to_ms("5m") == {:ok, 300_000}
    end

    test "parses hours" do
      assert Duration.to_ms("2h") == {:ok, 7_200_000}
    end

    test "rejects invalid formats" do
      assert Duration.to_ms("5") == :error
      assert Duration.to_ms("5d") == :error
      assert Duration.to_ms("m5") == :error
      assert Duration.to_ms("") == :error
      assert Duration.to_ms("0x1s") == :error
    end

    test "rejects zero" do
      assert Duration.to_ms("0s") == :error
    end
  end
end
