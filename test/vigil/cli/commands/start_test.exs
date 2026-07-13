defmodule Vigil.CLI.Commands.StartTest do
  use Vigil.RuntimeCase, async: false

  alias Vigil.Adapters.ControlSocket
  alias Vigil.CLI.Commands.Start
  alias Vigil.Core.MarketSnapshot
  alias Vigil.Runtime.{AssetWorker, WorkersSupervisor}

  import ExUnit.CaptureIO, only: [capture_io: 1]

  @fast_dir "test/fixtures/configs_fast"

  defmodule StubProvider do
    def fetch(_asset) do
      {:ok,
       struct!(MarketSnapshot,
         symbol: "PETR4.SA",
         timestamp: DateTime.utc_now(),
         open: 39.0,
         high: 41.0,
         low: 38.5,
         close: 39.0,
         price: 40.12,
         volume: 1_000
       )}
    end
  end

  defp tmp_socket_path do
    Path.join(System.tmp_dir!(), "vigil-start-test-#{System.unique_integer([:positive])}.sock")
  end

  # Returns the app to the quiescent state `Main.boot/0` leaves it in, so
  # later tests (and other test files) are unaffected.
  defp reset_app do
    Application.stop(:vigil)
    Application.put_env(:vigil, :start_runtime, false)
    Application.delete_env(:vigil, :config_dir)
    Application.delete_env(:vigil, :socket_path)
    {:ok, _apps} = Application.ensure_all_started(:vigil)
    :ok
  end

  setup do
    on_exit(fn ->
      # `Start.run/2` sets this app env as a side effect of a real `--config`
      # run — every test in this file passes `:config`, so it must be reset
      # or it leaks into unrelated tests (e.g. ConfigLoaderTest).
      Application.delete_env(:vigil, :config_dir)
    end)

    :ok
  end

  describe "invalid configuration" do
    test "aborts with exit 2 and renders the loader error to stderr" do
      assert {"", stderr, 2} = Start.run(config: "test/fixtures/nope")
      assert IO.iodata_to_binary(stderr) =~ "configuration directory not found"
    end

    test "aborts with exit 2 and renders json" do
      assert {"", stderr, 2} = Start.run(config: "test/fixtures/nope", format: "json")
      body = stderr |> IO.iodata_to_binary() |> Jason.decode!()
      assert body["ok"] == false
      assert [%{"message" => message}] = body["errors"]
      assert message =~ "configuration directory not found"
    end

    test "aborts with exit 2 on a per-resource config validation error" do
      dir =
        Path.join(System.tmp_dir!(), "vigil_start_invalid_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "assets"))

      File.write!(Path.join(dir, "assets/petr4.yaml"), """
      apiVersion: v1
      kind: Asset
      metadata:
        name: petr4
      spec:
        provider: yahoo
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      assert {"", stderr, 2} = Start.run(config: dir)
      assert IO.iodata_to_binary(stderr) =~ ~r/^error: Asset\/petr4:/
    end

    test "aborts with exit 2 and renders json on a per-resource config validation error" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "vigil_start_invalid_json_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(dir, "assets"))

      File.write!(Path.join(dir, "assets/petr4.yaml"), """
      apiVersion: v1
      kind: Asset
      metadata:
        name: petr4
      spec:
        provider: yahoo
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      assert {"", stderr, 2} = Start.run(config: dir, format: "json")
      body = stderr |> IO.iodata_to_binary() |> Jason.decode!()
      assert body["ok"] == false
      assert [%{"kind" => "Asset", "name" => "petr4"}] = body["errors"]
    end

    test "an unexpected app-start failure (not our own :invalid_config shape) falls back to raw rendering" do
      # Forces `Application.ensure_all_started/1` to fail for a reason that
      # does NOT match `extract_config_error/1`'s specific pattern (a name
      # clash on the top-level supervisor, rather than a rejected config) —
      # exercises the defensive fallback branch.
      # Free the `Vigil.Supervisor` name so the Agent below can claim it.
      Application.stop(:vigil)
      {:ok, agent} = Agent.start_link(fn -> :ok end, name: Vigil.Supervisor)

      on_exit(fn ->
        if Process.alive?(agent), do: Agent.stop(agent)
        Application.put_env(:vigil, :start_runtime, false)
        {:ok, _apps} = Application.ensure_all_started(:vigil)
      end)

      assert {"", stderr, 2} = Start.run(config: @fast_dir)
      assert IO.iodata_to_binary(stderr) =~ "error:"
    end
  end

  describe "successful start" do
    setup do
      TestSupport.put_provider(StubProvider)
      Application.put_env(:vigil, :socket_path, tmp_socket_path())

      on_exit(fn -> reset_app() end)

      :ok
    end

    test "starts the runtime, prints the banner, and returns without blocking" do
      output =
        capture_io(fn ->
          assert {"", "", 0} = Start.run([config: @fast_dir], fn -> :ok end)
        end)

      assert output =~ "vigil daemon started"
      assert output =~ "config: #{@fast_dir}"
      assert output =~ "socket: #{ControlSocket.path()}"

      # The Runtime actually started: WorkersSupervisor has the fixture's
      # single asset worker.
      assert [{_id, pid, :worker, _modules}] =
               DynamicSupervisor.which_children(WorkersSupervisor)

      assert is_pid(pid)
      assert AssetWorker.state(pid).asset.name == "petr4"
    end

    test "block_fun is invoked exactly once after a successful start" do
      test_pid = self()

      capture_io(fn ->
        Start.run([config: @fast_dir], fn -> send(test_pid, :blocked) end)
      end)

      assert_received :blocked
    end
  end
end
