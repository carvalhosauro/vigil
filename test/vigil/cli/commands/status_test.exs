defmodule Vigil.CLI.Commands.StatusTest do
  use ExUnit.Case, async: false

  alias Vigil.CLI.Commands.Status
  alias Vigil.CLI.Main
  alias Vigil.Core.Config.Asset
  alias Vigil.Core.MarketSnapshot
  alias Vigil.Runtime.{AssetWorker, Control, WorkersSupervisor}

  @registry Vigil.Runtime.WorkerRegistry

  defmodule OkProvider do
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

  defp asset, do: %Asset{name: "petr4", symbol: "PETR4.SA", provider: "yahoo", interval: "1s"}

  # Unix `sun_path` is capped at ~108 bytes on Linux; a short `/tmp` name
  # (never the long per-session scratchpad path) keeps every socket bindable.
  defp tmp_socket_path do
    Path.join(System.tmp_dir!(), "vg-status-#{System.unique_integer([:positive])}.sock")
  end

  defp start_task_supervisors do
    start_supervised!({Task.Supervisor, name: __MODULE__.CycleSup})
    start_supervised!({Task.Supervisor, name: __MODULE__.DispatchSup})
    :ok
  end

  defp worker_spec(id) do
    Application.put_env(:vigil, :providers, %{"yahoo" => OkProvider})
    on_exit(fn -> Application.delete_env(:vigil, :providers) end)

    {AssetWorker,
     asset: asset(),
     rules: [],
     cycle_task_supervisor: __MODULE__.CycleSup,
     dispatch_task_supervisor: __MODULE__.DispatchSup,
     name: {:via, Registry, {@registry, id}}}
  end

  defp start_workers(specs) do
    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!(WorkersSupervisor)

    Enum.each(specs, fn spec ->
      {:ok, _pid} = DynamicSupervisor.start_child(WorkersSupervisor, spec)
    end)

    :ok
  end

  defp start_control(path) do
    start_supervised!({Control, path: path})
    path
  end

  # A throwaway raw listener standing in for a daemon that answers the
  # connection but sends back unusable bytes — exercises the "daemon
  # answered but unusably" exit-1 path, distinct from "not reachable".
  defp start_bogus_listener(path, reply) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, client} = :gen_tcp.accept(listen_socket)
        :gen_tcp.send(client, reply)
        :gen_tcp.close(client)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
      File.rm(path)
    end)

    {pid, listen_socket}
  end

  describe "reachable daemon (integration, real socket)" do
    setup do
      start_task_supervisors()

      ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])
      start_workers([worker_spec("petr4")])
      assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

      path = tmp_socket_path()
      start_control(path)

      {:ok, path: path}
    end

    test "text output has the header, the petr4 row, and its state", %{path: path} do
      assert {stdout, "", 0} = Status.run(socket: path)
      text = IO.iodata_to_binary(stdout)

      lines = String.split(text, "\n", trim: true)
      assert [header | rows] = lines

      assert header =~ ~r/asset\s+provider\s+interval\s+last_update\s+state/
      assert [row] = rows
      assert row =~ "petr4"
      assert row =~ "yahoo"
      assert row =~ "1s"
      assert row =~ "online"
    end

    test "json output round-trips the daemon payload", %{path: path} do
      assert {stdout, "", 0} = Status.run(socket: path, format: "json")
      body = stdout |> IO.iodata_to_binary() |> Jason.decode!()

      assert %{"version" => _vsn, "assets" => [asset]} = body
      assert asset["name"] == "petr4"
      assert asset["state"] == "online"
    end

    test "unknown --format falls back to text", %{path: path} do
      assert {stdout, "", 0} = Status.run(socket: path, format: "xml")
      assert IO.iodata_to_binary(stdout) =~ "asset"
    end
  end

  describe "daemon not reachable" do
    test "no socket file at all exits 3" do
      path = tmp_socket_path()
      refute File.exists?(path)

      assert {"", stderr, 3} = Status.run(socket: path)
      assert IO.iodata_to_binary(stderr) =~ "daemon not reachable"
      assert IO.iodata_to_binary(stderr) =~ path
    end

    test "a stale socket file with no listener exits 3" do
      path = tmp_socket_path()
      File.write!(path, "stale")
      on_exit(fn -> File.rm(path) end)

      assert {"", stderr, 3} = Status.run(socket: path)
      assert IO.iodata_to_binary(stderr) =~ "daemon not reachable"
    end
  end

  describe "malformed daemon reply" do
    test "non-JSON reply exits 1 with a malformed-response message" do
      path = tmp_socket_path()
      start_bogus_listener(path, "not json\n")

      assert {"", stderr, 1} = Status.run(socket: path)
      stderr = IO.iodata_to_binary(stderr)
      assert stderr =~ "malformed" or stderr =~ "invalid"
    end

    test "valid JSON missing the assets key exits 1" do
      path = tmp_socket_path()
      start_bogus_listener(path, Jason.encode!(%{"version" => "1.0.0"}) <> "\n")

      assert {"", stderr, 1} = Status.run(socket: path)
      assert IO.iodata_to_binary(stderr) =~ "malformed"
    end

    test "an empty reply (connection closed with no bytes) exits 1" do
      path = tmp_socket_path()
      start_bogus_listener(path, "")

      assert {"", stderr, 1} = Status.run(socket: path)
      assert IO.iodata_to_binary(stderr) =~ "malformed"
    end
  end

  describe "null last_update renders as never" do
    test "text output shows never for a null last_update" do
      path = tmp_socket_path()

      payload = %{
        "version" => "1.0.0",
        "assets" => [
          %{
            "name" => "vale3",
            "provider" => "yahoo",
            "interval" => "1m",
            "last_update" => nil,
            "consecutive_failures" => nil,
            "state" => "offline"
          }
        ]
      }

      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {stdout, "", 0} = Status.run(socket: path)
      text = IO.iodata_to_binary(stdout)
      assert text =~ "never"
      assert text =~ "vale3"
      assert text =~ "offline"
    end

    test "an offline worker with nil provider/interval still renders a row" do
      path = tmp_socket_path()

      payload = %{
        "version" => "1.0.0",
        "assets" => [
          %{
            "name" => "slow",
            "provider" => nil,
            "interval" => nil,
            "last_update" => nil,
            "consecutive_failures" => nil,
            "state" => "offline",
            "note" => "boom"
          }
        ]
      }

      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {stdout, "", 0} = Status.run(socket: path)
      text = IO.iodata_to_binary(stdout)
      assert text =~ "slow"
      assert text =~ "never"
      assert text =~ "offline"
    end
  end

  describe "empty asset list (daemon up, zero workers)" do
    test "renders the header only, with no data rows, exit 0" do
      path = tmp_socket_path()
      start_bogus_listener(path, Jason.encode!(%{"version" => "1.0.0", "assets" => []}) <> "\n")

      assert {stdout, "", 0} = Status.run(socket: path)

      lines = stdout |> IO.iodata_to_binary() |> String.split("\n", trim: true)
      assert [header] = lines
      assert header =~ "asset"
      assert header =~ "state"
    end
  end

  describe "Main wiring" do
    test "Main.run(status) returns the daemon-not-reachable tuple" do
      path = tmp_socket_path()
      assert {"", stderr, 3} = Main.run(["status", "--socket", path])
      assert IO.iodata_to_binary(stderr) =~ "daemon not reachable"
    end

    test "Main.run(status, --format json) is dispatched" do
      start_task_supervisors()

      ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])
      start_workers([worker_spec("petr4")])
      assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

      path = tmp_socket_path()
      start_control(path)

      assert {stdout, "", 0} = Main.run(["status", "--socket", path, "--format", "json"])

      assert %{"assets" => [%{"name" => "petr4"}]} =
               stdout |> IO.iodata_to_binary() |> Jason.decode!()
    end

    test "Main.run(status) with an unknown --format is rejected before dispatch" do
      # `Main.dispatch/2` validates `--format` itself before reaching any
      # command (see `main_test.exs`'s equivalent case for `validate`), so
      # this never reaches `Status.run/1`'s own text-fallback clause — that
      # clause is exercised by calling `Status.run/1` directly, above.
      path = tmp_socket_path()
      assert {"", stderr, 1} = Main.run(["status", "--socket", path, "--format", "bogus"])
      assert IO.iodata_to_binary(stderr) =~ "invalid --format"
    end
  end
end
