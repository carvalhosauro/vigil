defmodule VigilTest do
  use ExUnit.Case, async: true

  test "version/0 returns a version string" do
    assert is_binary(Vigil.version())
  end
end
