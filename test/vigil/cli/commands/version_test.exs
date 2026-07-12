defmodule Vigil.CLI.Commands.VersionTest do
  use ExUnit.Case, async: true

  alias Vigil.CLI.Commands.Version

  test "text format prints vigil <version> and exits 0" do
    vsn = Application.spec(:vigil, :vsn) |> to_string()

    assert Version.run([]) == {"vigil #{vsn}\n", "", 0}
    assert Version.run(format: "text") == {"vigil #{vsn}\n", "", 0}
  end

  test "json format prints {\"vigil\": <version>} and exits 0" do
    vsn = Application.spec(:vigil, :vsn) |> to_string()

    assert {stdout, "", 0} = Version.run(format: "json")
    assert Jason.decode!(stdout) == %{"vigil" => vsn}
  end
end
