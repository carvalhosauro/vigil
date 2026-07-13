defmodule Vigil.CLI.Commands.ValidateTest do
  use ExUnit.Case, async: false

  alias Vigil.CLI.Commands.Validate
  alias Vigil.TestSupport

  @valid_dir "test/fixtures/configs_valid"

  setup do
    TestSupport.put_telegram_env()
  end

  describe "success" do
    test "text format reports counts and exits 0" do
      assert Validate.run(config: @valid_dir) ==
               {"ok: 1 assets, 1 rules, 1 notifiers\n", "", 0}
    end

    test "json format reports counts and exits 0" do
      assert {stdout, "", 0} = Validate.run(config: @valid_dir, format: "json")

      assert Jason.decode!(stdout) == %{
               "ok" => true,
               "assets" => 1,
               "rules" => 1,
               "notifiers" => 1
             }
    end

    test "defaults to ConfigLoader.config_dir/0 when :config is absent" do
      Application.put_env(:vigil, :config_dir, @valid_dir)
      on_exit(fn -> Application.delete_env(:vigil, :config_dir) end)

      assert Validate.run([]) == {"ok: 1 assets, 1 rules, 1 notifiers\n", "", 0}
    end
  end

  describe "config validation errors" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "vigil_cli_invalid_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "a_asset.yaml"), """
      apiVersion: v1
      kind: Asset
      metadata:
        name: petr4
      spec:
        provider: yahoo
      """)

      # Missing `asset` — this is a per-resource parse-level error (unlike an
      # unknown asset *reference*, which is a resolve-phase error that never
      # runs when any resource fails to parse — see Config.validate/1 doc).
      File.write!(Path.join(dir, "b_rule.yaml"), """
      apiVersion: v1
      kind: Rule
      metadata:
        name: breakout
      spec:
        when:
          all:
            - field: price
              op: gt
              value: 40
        actions:
          - telegram
      """)

      %{dir: dir}
    end

    test "text format lists every error, in input order, to stderr with exit 2", %{dir: dir} do
      assert {"", stderr, 2} = Validate.run(config: dir)

      lines = stderr |> IO.iodata_to_binary() |> String.split("\n", trim: true)

      assert length(lines) == 2
      assert Enum.at(lines, 0) =~ ~r/^error: Asset\/petr4:/
      assert Enum.at(lines, 1) =~ ~r/^error: Rule\/breakout:/
    end

    test "json format lists every error with exit 2", %{dir: dir} do
      assert {"", stderr, 2} = Validate.run(config: dir, format: "json")

      body = stderr |> IO.iodata_to_binary() |> Jason.decode!()

      assert body["ok"] == false

      assert [%{"kind" => "Asset", "name" => "petr4"}, %{"kind" => "Rule", "name" => "breakout"}] =
               body["errors"]
    end
  end

  describe "loader-level failures" do
    test "nonexistent config directory" do
      assert {"", stderr, 2} = Validate.run(config: "test/fixtures/nope")
      assert IO.iodata_to_binary(stderr) =~ "configuration directory not found"
    end

    test "nonexistent config directory (json)" do
      assert {"", stderr, 2} = Validate.run(config: "test/fixtures/nope", format: "json")
      body = stderr |> IO.iodata_to_binary() |> Jason.decode!()
      assert body["ok"] == false
      assert [%{"message" => message}] = body["errors"]
      assert message =~ "configuration directory not found"
    end

    test "missing env vars" do
      System.delete_env("CHAT_ID")

      assert {"", stderr, 2} = Validate.run(config: @valid_dir)
      assert IO.iodata_to_binary(stderr) =~ "missing required environment variable(s): CHAT_ID"
    end
  end
end
