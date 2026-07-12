defmodule Vigil.CLI.MainTest do
  use ExUnit.Case, async: false

  alias Vigil.CLI.Main

  import ExUnit.CaptureIO, only: [capture_io: 1, capture_io: 2]

  @valid_dir "test/fixtures/configs_valid"

  setup do
    System.put_env("TELEGRAM_TOKEN", "tok")
    System.put_env("CHAT_ID", "123")

    on_exit(fn ->
      System.delete_env("TELEGRAM_TOKEN")
      System.delete_env("CHAT_ID")
      Logger.configure(level: :warning)
    end)
  end

  describe "version" do
    test "runs with no options" do
      vsn = Application.spec(:vigil, :vsn) |> to_string()
      assert Main.run(["version"]) == {"vigil #{vsn}\n", "", 0}
    end

    test "--format json" do
      assert {stdout, "", 0} = Main.run(["version", "--format", "json"])
      assert %{"vigil" => _} = Jason.decode!(stdout)
    end
  end

  describe "validate" do
    test "--config overrides the directory" do
      assert Main.run(["validate", "--config", @valid_dir]) ==
               {"ok: 1 assets, 1 rules, 1 notifiers\n", "", 0}
    end

    test "--config can come before the command" do
      assert Main.run(["--config", @valid_dir, "validate"]) ==
               {"ok: 1 assets, 1 rules, 1 notifiers\n", "", 0}
    end

    test "--config wins over a set VIGIL_CONFIG_DIR (RFC-0010 §5)" do
      System.put_env("VIGIL_CONFIG_DIR", "/nonexistent-from-env")
      on_exit(fn -> System.delete_env("VIGIL_CONFIG_DIR") end)

      assert Main.run(["validate", "--config", @valid_dir]) ==
               {"ok: 1 assets, 1 rules, 1 notifiers\n", "", 0}
    end

    test "nonexistent config dir exits 2" do
      assert {"", stderr, 2} = Main.run(["validate", "--config", "/nonexistent"])
      assert IO.iodata_to_binary(stderr) =~ "configuration directory not found"
    end

    test "--log-level is accepted and applied" do
      assert Main.run(["validate", "--config", @valid_dir, "--log-level", "debug"]) ==
               {"ok: 1 assets, 1 rules, 1 notifiers\n", "", 0}

      assert Logger.level() == :debug
    end
  end

  describe "boot/0" do
    test "disables the Runtime supervisor and starts the :vigil application" do
      assert Main.boot() == :ok
      assert Application.get_env(:vigil, :start_runtime, true) == false
    end
  end

  describe "print/2" do
    test "writes stdout and stderr to the matching IO device" do
      assert capture_io(fn ->
               assert capture_io(:stderr, fn ->
                        Main.print("out\n", "err\n")
                      end) == "err\n"
             end) == "out\n"
    end
  end

  describe "usage errors" do
    test "missing command exits 1 with usage on stderr" do
      assert {"", stderr, 1} = Main.run([])
      stderr = IO.iodata_to_binary(stderr)
      assert stderr =~ "error: missing command"
      assert stderr =~ "Usage: vigil"
    end

    test "unknown command exits 1 with usage on stderr" do
      assert {"", stderr, 1} = Main.run(["frobnicate"])
      stderr = IO.iodata_to_binary(stderr)
      assert stderr =~ ~s(error: unknown command "frobnicate")
      assert stderr =~ "Usage: vigil"
    end

    test "unknown option exits 1" do
      assert {"", stderr, 1} = Main.run(["validate", "--bogus", "x"])
      assert IO.iodata_to_binary(stderr) =~ "error: unknown option --bogus"
    end

    test "invalid --format exits 1" do
      assert {"", stderr, 1} = Main.run(["validate", "--format", "xml"])
      assert IO.iodata_to_binary(stderr) =~ ~s(invalid --format "xml")
    end

    test "invalid --log-level exits 1" do
      assert {"", stderr, 1} = Main.run(["validate", "--log-level", "screaming"])
      assert IO.iodata_to_binary(stderr) =~ ~s(invalid --log-level "screaming")
    end
  end
end
