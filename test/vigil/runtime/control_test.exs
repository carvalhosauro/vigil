defmodule Vigil.Runtime.ControlTest do
  use ExUnit.Case, async: false

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

  # A raw process that answers nothing — simulates a worker that never
  # replies to `AssetWorker.state/1`'s `GenServer.call`, so the request times
  # out (Control's per-worker catch must turn that into an "offline" entry
  # instead of crashing the whole status reply). Registers itself under its
  # own name so Control's Registry-based fallback lookup still finds it.
  defmodule UnresponsiveStub do
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
    end

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      registry = Keyword.fetch!(opts, :registry)

      {:ok,
       spawn_link(fn ->
         Registry.register(registry, name, nil)
         Process.sleep(:infinity)
       end)}
    end
  end

  defp asset, do: %Asset{name: "petr4", symbol: "PETR4.SA", provider: "yahoo", interval: "1s"}

  defp tmp_socket_path do
    Path.join(System.tmp_dir!(), "vigil-control-test-#{System.unique_integer([:positive])}.sock")
  end

  defp start_task_supervisors do
    start_supervised!({Task.Supervisor, name: __MODULE__.CycleSup})
    start_supervised!({Task.Supervisor, name: __MODULE__.DispatchSup})
    :ok
  end

  defp via(name), do: {:via, Registry, {@registry, name}}

  defp worker_spec(id, opts \\ []) do
    provider = Keyword.get(opts, :provider, OkProvider)
    Application.put_env(:vigil, :providers, %{"yahoo" => provider})
    on_exit(fn -> Application.delete_env(:vigil, :providers) end)

    {AssetWorker,
     asset: asset(),
     rules: [],
     cycle_task_supervisor: __MODULE__.CycleSup,
     dispatch_task_supervisor: __MODULE__.DispatchSup,
     name: via(id)}
  end

  defp start_workers(specs) do
    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!(WorkersSupervisor)

    Enum.each(specs, fn spec ->
      {:ok, _pid} = DynamicSupervisor.start_child(WorkersSupervisor, spec)
    end)

    :ok
  end

  defp start_control(opts \\ []) do
    path = Keyword.get(opts, :path, tmp_socket_path())
    start_supervised!({Control, path: path})
    path
  end

  defp request(path, line) do
    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
    :ok = :gen_tcp.send(socket, line)
    result = :gen_tcp.recv(socket, 0, 7_000)
    :gen_tcp.close(socket)
    result
  end

  test "reports an online asset after a successful cycle" do
    start_task_supervisors()

    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])
    start_workers([worker_spec("petr4")])
    assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

    path = start_control()

    assert {:ok, line} = request(path, "status\n")
    body = Jason.decode!(line)

    assert %{"version" => _vsn, "assets" => [asset]} = body

    assert %{
             "name" => "petr4",
             "provider" => "yahoo",
             "interval" => "1s",
             "consecutive_failures" => 0,
             "state" => "online"
           } = asset

    assert %{"last_update" => last_update} = asset
    assert {:ok, _dt, _off} = DateTime.from_iso8601(last_update)
  end

  test "0600 permissions on the socket file" do
    start_task_supervisors()
    start_workers([worker_spec("petr4")])
    path = start_control()

    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "removes a stale socket file left over from an unclean shutdown" do
    path = tmp_socket_path()
    File.write!(path, "stale")

    start_task_supervisors()
    start_workers([worker_spec("petr4")])
    start_control(path: path)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "removes the socket file on terminate" do
    start_task_supervisors()
    start_workers([worker_spec("petr4")])
    path = start_control()

    assert File.exists?(path)
    :ok = stop_supervised(Control)
    refute File.exists?(path)
  end

  test "unknown requests get a JSON error line and the connection is closed" do
    start_task_supervisors()
    start_workers([worker_spec("petr4")])
    path = start_control()

    assert {:ok, line} = request(path, "bogus\n")
    assert Jason.decode!(line) == %{"error" => "unknown request"}
  end

  test "a reload request with no Reconciler running answers ok:false instead of crashing" do
    # This harness starts Registry/WorkersSupervisor/Control directly (unlike
    # the "reload request" describe block below, which boots the full
    # `Vigil.Runtime.Supervisor` tree) — there is no `Vigil.Runtime.Reconciler`
    # process registered, so `Reconciler.reconcile/0`'s `GenServer.call` exits
    # `{:noproc, ...}`. `safe_reconcile/0` must turn that into a JSON error
    # reply rather than crashing the client task.
    start_task_supervisors()
    start_workers([worker_spec("petr4")])
    path = start_control()

    assert {:ok, line} = request(path, "reload\n")
    body = Jason.decode!(line)

    assert body["ok"] == false
    assert is_binary(body["error"])
  end

  test "a worker that never replies degrades gracefully instead of crashing the reply" do
    start_task_supervisors()

    dead_spec = {UnresponsiveStub, name: "slow", registry: @registry}

    start_workers([worker_spec("petr4"), dead_spec])

    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])
    assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

    path = start_control()

    assert {:ok, line} = request(path, "status\n")
    body = Jason.decode!(line)

    names = Enum.map(body["assets"], & &1["name"])
    assert "petr4" in names
    assert "slow" in names

    slow = Enum.find(body["assets"], &(&1["name"] == "slow"))
    assert slow["state"] == "offline"
    assert slow["provider"] == nil
  end

  test "a dead worker with no Registry entry reports name \"unknown\" instead of crashing" do
    start_task_supervisors()

    unregistered_spec = %{
      id: :unregistered,
      start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]},
      restart: :temporary
    }

    start_workers([worker_spec("petr4"), unregistered_spec])

    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])
    assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

    path = start_control()

    assert {:ok, line} = request(path, "status\n")
    body = Jason.decode!(line)

    names = Enum.map(body["assets"], & &1["name"])
    assert "petr4" in names
    assert "unknown" in names
  end

  test "a degraded asset (1-2 consecutive failures with a prior success)" do
    start_task_supervisors()
    start_workers([worker_spec("petr4")])

    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])
    assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

    [{worker_pid, _value}] = Registry.lookup(@registry, "petr4")

    :sys.replace_state(worker_pid, fn worker_state ->
      health = %{worker_state.vigil_state.health | consecutive_failures: 2}
      %{worker_state | vigil_state: %{worker_state.vigil_state | health: health}}
    end)

    path = start_control()

    assert {:ok, line} = request(path, "status\n")
    body = Jason.decode!(line)

    assert [%{"name" => "petr4", "state" => "degraded", "consecutive_failures" => 2}] =
             body["assets"]
  end

  test "offline when consecutive_failures >= 3 despite a prior success" do
    start_task_supervisors()
    start_workers([worker_spec("petr4")])

    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])
    assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

    [{worker_pid, _value}] = Registry.lookup(@registry, "petr4")

    :sys.replace_state(worker_pid, fn worker_state ->
      health = %{worker_state.vigil_state.health | consecutive_failures: 3}
      %{worker_state | vigil_state: %{worker_state.vigil_state | health: health}}
    end)

    path = start_control()

    assert {:ok, line} = request(path, "status\n")
    body = Jason.decode!(line)

    assert [%{"name" => "petr4", "state" => "offline", "consecutive_failures" => 3}] =
             body["assets"]
  end

  test "offline (never succeeded) reports a nil last_update even for a responsive worker" do
    start_task_supervisors()
    start_workers([worker_spec("petr4")])

    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])
    assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

    [{worker_pid, _value}] = Registry.lookup(@registry, "petr4")

    :sys.replace_state(worker_pid, fn worker_state ->
      health = %{worker_state.vigil_state.health | last_success: nil, consecutive_failures: 0}
      %{worker_state | vigil_state: %{worker_state.vigil_state | health: health}}
    end)

    path = start_control()

    assert {:ok, line} = request(path, "status\n")
    body = Jason.decode!(line)

    assert [%{"name" => "petr4", "state" => "offline", "last_update" => nil}] = body["assets"]
  end

  test "init returns {:stop, {:listen_failed, ...}} when the socket path cannot be bound" do
    # A path inside a nonexistent directory can never be bound.
    bogus_path =
      Path.join([
        System.tmp_dir!(),
        "vigil-nonexistent-#{System.unique_integer([:positive])}",
        "vigil.sock"
      ])

    Process.flag(:trap_exit, true)
    assert {:error, {:listen_failed, ^bogus_path, _reason}} = Control.start_link(path: bogus_path)
  end

  test "an EXIT message from a process other than the acceptor is ignored" do
    start_task_supervisors()
    start_workers([worker_spec("petr4")])
    path = start_control()

    control_pid = Process.whereis(Control)
    send(control_pid, {:EXIT, self(), :normal})

    # The Control process is still alive and answers normally.
    assert Process.alive?(control_pid)
    assert {:ok, _line} = request(path, "status\n")
  end

  test "the acceptor crashing abnormally stops Control" do
    start_task_supervisors()
    start_workers([worker_spec("petr4")])
    start_control()

    control_pid = Process.whereis(Control)
    %{acceptor: acceptor_pid} = :sys.get_state(control_pid)

    ref = Process.monitor(control_pid)
    Process.exit(acceptor_pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^control_pid, {:acceptor_crashed, :killed}}, 2_000
  end

  describe "accept_error_action/1" do
    test ":closed (clean shutdown) halts the loop" do
      assert Control.accept_error_action(:closed) == :halt
    end

    test ":econnaborted (client vanished) retries the loop" do
      assert Control.accept_error_action(:econnaborted) == :retry
    end

    test "any other error crashes so rest_for_one restarts the channel" do
      assert Control.accept_error_action(:emfile) == :crash
      assert Control.accept_error_action(:enfile) == :crash
      assert Control.accept_error_action(:badarg) == :crash
    end
  end

  describe "accept_loop/2 error handling" do
    test "a transient error is retried, then a clean :closed halts the loop" do
      # Fake accept: one transient failure, then a clean-shutdown close.
      {:ok, agent} = Agent.start_link(fn -> [{:error, :econnaborted}, {:error, :closed}] end)

      accept_fun = fn _sock ->
        Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      end

      # Returns normally (loop halted) only if the transient error was retried
      # rather than treated as terminal.
      assert Control.accept_loop(:fake_socket, accept_fun) == :ok
      assert Agent.get(agent, & &1) == []
    end

    test "an unexpected error exits {:accept_failed, reason}" do
      accept_fun = fn _sock -> {:error, :emfile} end

      {_pid, ref} =
        spawn_monitor(fn -> Control.accept_loop(:fake_socket, accept_fun) end)

      assert_receive {:DOWN, ^ref, :process, _pid, {:accept_failed, :emfile}}, 1_000
    end
  end

  test "a client that disconnects without sending a line does not crash the server" do
    start_task_supervisors()
    start_workers([worker_spec("petr4")])
    path = start_control()

    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
    :ok = :gen_tcp.close(socket)

    # The server is still up for the next request.
    Process.sleep(50)
    assert {:ok, _line} = request(path, "status\n")
  end

  describe "reload request" do
    @base_fixture "test/fixtures/reload/base"
    @itub4_fixture "test/fixtures/reload/added/assets/itub4.yaml"

    setup do
      System.put_env("TELEGRAM_TOKEN", "tok")
      System.put_env("CHAT_ID", "123")
      Application.put_env(:vigil, :providers, %{"yahoo" => OkProvider})

      dir =
        Path.join(System.tmp_dir!(), "vigil-ctl-reload-#{System.unique_integer([:positive])}")

      File.cp_r!(@base_fixture, dir)

      path = tmp_socket_path()
      Application.put_env(:vigil, :socket_path, path)

      on_exit(fn ->
        System.delete_env("TELEGRAM_TOKEN")
        System.delete_env("CHAT_ID")
        Application.delete_env(:vigil, :providers)
        Application.delete_env(:vigil, :socket_path)
        File.rm_rf!(dir)
      end)

      ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])
      start_supervised!({Vigil.Runtime.Supervisor, config_dir: dir})
      assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

      {:ok, dir: dir, path: path}
    end

    test "no changes on disk reports an empty diff", %{path: path} do
      assert {:ok, line} = request(path, "reload\n")

      assert Jason.decode!(line) == %{
               "ok" => true,
               "added" => [],
               "changed" => [],
               "removed" => []
             }
    end

    test "an added asset file is reported as added and its worker starts", %{
      path: path,
      dir: dir
    } do
      File.cp!(@itub4_fixture, Path.join(dir, "assets/itub4.yaml"))

      assert {:ok, line} = request(path, "reload\n")
      body = Jason.decode!(line)

      assert body == %{"ok" => true, "added" => ["itub4"], "changed" => [], "removed" => []}
      assert [{_pid, _value}] = Registry.lookup(@registry, "itub4")
    end

    test "an invalid on-disk config is rejected and running workers are untouched", %{
      path: path,
      dir: dir
    } do
      File.write!(Path.join(dir, "assets/petr4.yaml"), """
      apiVersion: v1
      kind: Asset
      metadata:
        name: petr4
      spec:
        provider: yahoo
      """)

      assert {:ok, pid_before} = worker_pid_in(@registry, "petr4")

      assert {:ok, line} = request(path, "reload\n")
      body = Jason.decode!(line)

      assert %{"ok" => false, "error" => error} = body
      assert is_binary(error)

      assert {:ok, ^pid_before} = worker_pid_in(@registry, "petr4")
      assert [{_pid, _value}] = Registry.lookup(@registry, "vale3")
    end

    test "the on-disk config directory vanishing produces a non-list rejection reason", %{
      path: path,
      dir: dir
    } do
      # `ConfigLoader.load/1` fails at the loader stage here (`{:config_dir_not_found,
      # dir}`), before `Config.validate/1` ever produces a list of `Config.Error`
      # structs — `render_reject_reason/1`'s catch-all clause must still
      # render it instead of raising a `FunctionClauseError`.
      File.rm_rf!(dir)

      assert {:ok, line} = request(path, "reload\n")
      body = Jason.decode!(line)

      assert %{"ok" => false, "error" => error} = body
      assert is_binary(error)
    end

    test "the acceptor survives a reload and still handles subsequent requests", %{path: path} do
      assert {:ok, _line} = request(path, "reload\n")
      assert {:ok, line} = request(path, "bogus\n")
      assert Jason.decode!(line) == %{"error" => "unknown request"}
      assert {:ok, _line} = request(path, "status\n")
    end
  end

  defp worker_pid_in(registry, name) do
    case Registry.lookup(registry, name) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  describe "full loop through Vigil.Runtime.Supervisor" do
    test "a status request against the real supervised topology sees petr4 online" do
      System.put_env("TELEGRAM_TOKEN", "tok")
      System.put_env("CHAT_ID", "123")
      Application.put_env(:vigil, :providers, %{"yahoo" => OkProvider})
      path = tmp_socket_path()
      Application.put_env(:vigil, :socket_path, path)

      on_exit(fn ->
        System.delete_env("TELEGRAM_TOKEN")
        System.delete_env("CHAT_ID")
        Application.delete_env(:vigil, :providers)
        Application.delete_env(:vigil, :socket_path)
      end)

      ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])

      start_supervised!({Vigil.Runtime.Supervisor, config_dir: "test/fixtures/configs_fast"})

      assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

      assert {:ok, line} = request(path, "status\n")
      body = Jason.decode!(line)

      assert [%{"name" => "petr4", "state" => "online"}] = body["assets"]
    end
  end
end
