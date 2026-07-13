defmodule Vigil.Runtime.WatcherTest do
  use Vigil.RuntimeCase, async: false

  alias Vigil.Core.MarketSnapshot
  alias Vigil.Runtime.Watcher

  @registry Vigil.Runtime.WorkerRegistry
  @base "test/fixtures/reload/base"
  @itub4_fixture "test/fixtures/reload/added/assets/itub4.yaml"

  defmodule OkProvider do
    def fetch(_asset) do
      {:ok,
       struct!(MarketSnapshot,
         symbol: "STUB",
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

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  defp worker_pid(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  # ---------------------------------------------------------------------
  # Synthetic-message driven debounce tests.
  #
  # The Watcher's own debounce logic doesn't care where a `:file_event`
  # message came from — only that one arrived. Driving `handle_info/2`
  # directly this way tests the debounce/coalescing behavior deterministically
  # and instantly, instead of depending on real OS file-watch timing (which
  # varies by backend/platform and would make these tests flaky).
  # ---------------------------------------------------------------------

  # `start_watch_fun` is stubbed to skip the real `file_system` backend
  # entirely: it just returns a live dummy pid as the "backend", which the
  # test then impersonates by sending `:file_event` messages straight to the
  # Watcher itself.
  defp start_synthetic_watcher(opts \\ []) do
    test_pid = self()
    backend_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(backend_pid, :kill) end)

    reconcile_fun =
      Keyword.get_lazy(opts, :reconcile_fun, fn ->
        fn ->
          send(test_pid, :reconciled)
          {:ok, %{}}
        end
      end)

    watcher_opts = [
      config_dir: "unused",
      debounce_ms: Keyword.get(opts, :debounce_ms, 50),
      start_watch_fun: fn _dir -> {:ok, backend_pid} end,
      reconcile_fun: reconcile_fun
    ]

    {:ok, pid} = Watcher.start_link(watcher_opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, backend_pid}
  end

  test "debounce: several rapid file events collapse into a single reconcile" do
    {pid, backend_pid} = start_synthetic_watcher(debounce_ms: 50)

    for _ <- 1..5 do
      send(pid, {:file_event, backend_pid, {"assets/foo.yaml", [:modified]}})
    end

    assert_receive :reconciled, 500
    refute_receive :reconciled, 200
  end

  test "debounce timer reset: an event during the quiet period pushes reconcile later" do
    {pid, backend_pid} = start_synthetic_watcher(debounce_ms: 100)

    send(pid, {:file_event, backend_pid, {"assets/foo.yaml", [:created]}})
    Process.sleep(60)
    # Without a reset, the first event's timer would already be firing within
    # the next ~40ms — this second event must push it back out.
    send(pid, {:file_event, backend_pid, {"assets/foo.yaml", [:modified]}})

    refute_receive :reconciled, 60
    assert_receive :reconciled, 300
  end

  test "a timer that fires while an event is queued still coalesces to one reconcile" do
    # Reproduces the debounce boundary race deterministically via suspend:
    # event A schedules the timer, the process is suspended, event B is queued,
    # then A's timer fires (its :debounced_reconcile lands in the mailbox
    # BEHIND B). On resume, B is processed first with the timer still set —
    # the reset must flush the stale :debounced_reconcile so only B's fresh
    # timer reconciles. Without the flush, both fire → two reconciles.
    {pid, backend_pid} = start_synthetic_watcher(debounce_ms: 100)

    send(pid, {:file_event, backend_pid, {"assets/foo.yaml", [:created]}})
    :sys.suspend(pid)
    send(pid, {:file_event, backend_pid, {"assets/bar.yaml", [:modified]}})
    # Let event A's timer fire while suspended, so its message queues behind B.
    Process.sleep(150)
    :sys.resume(pid)

    assert_receive :reconciled, 300
    refute_receive :reconciled, 200
  end

  test "a rejected reconcile does not crash the watcher" do
    {pid, backend_pid} =
      start_synthetic_watcher(debounce_ms: 30, reconcile_fun: fn -> {:error, :invalid} end)

    send(pid, {:file_event, backend_pid, {"assets/foo.yaml", [:modified]}})
    Process.sleep(100)

    assert Process.alive?(pid)
  end

  test "a reconcile that raises does not crash the watcher" do
    {pid, backend_pid} =
      start_synthetic_watcher(debounce_ms: 30, reconcile_fun: fn -> raise "boom" end)

    send(pid, {:file_event, backend_pid, {"assets/foo.yaml", [:modified]}})
    Process.sleep(100)

    assert Process.alive?(pid)
  end

  test "a reconcile that exits does not crash the watcher" do
    {pid, backend_pid} =
      start_synthetic_watcher(debounce_ms: 30, reconcile_fun: fn -> exit(:boom) end)

    send(pid, {:file_event, backend_pid, {"assets/foo.yaml", [:modified]}})
    Process.sleep(100)

    assert Process.alive?(pid)
  end

  test "the :stop backend message stops the watcher so its supervisor can restart it" do
    # `Watcher.start_link/1` links to this test process — trap_exit so the
    # Watcher's own intentional (but non-`:normal`) `{:stop, ...}` doesn't
    # propagate up and kill the test itself, mirroring how ControlTest handles
    # the same shape of assertion.
    Process.flag(:trap_exit, true)
    {pid, backend_pid} = start_synthetic_watcher()
    ref = Process.monitor(pid)

    send(pid, {:file_event, backend_pid, :stop})

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :file_system_backend_stopped}}, 500
  end

  test "starts in a degraded (non-watching) state instead of failing when the backend can't start" do
    assert {:ok, pid} =
             Watcher.start_link(
               config_dir: "some/dir",
               start_watch_fun: fn _dir -> {:error, :boom} end
             )

    # Degraded, not dead: automatic reload is unavailable, but the process
    # itself (and, wired under `Runtime.Supervisor`, the rest of the tree —
    # including manual `vigil reload`) is unaffected.
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  # ---------------------------------------------------------------------
  # A real `file_system` backend, driven by an actual on-disk file change —
  # exercises `default_start_watch/2` itself (the only production code path
  # the synthetic tests above don't reach). Forces the bundled `:fs_poll`
  # backend rather than relying on the platform's native watcher (inotify on
  # Linux, FSEvents on macOS): those need an external binary/service that may
  # not be present in every environment (this sandbox has neither
  # `inotify-tools` nor a real filesystem event source), so `:fs_poll` keeps
  # this genuinely real (no stubbed backend) while staying deterministic and
  # portable across whatever CI runs it.
  # ---------------------------------------------------------------------

  test "a real file_system backend (portable :fs_poll) reports an actual on-disk change" do
    test_pid = self()

    dir =
      Path.join(System.tmp_dir!(), "vigil-watcher-real-fs-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, pid} =
      Watcher.start_link(
        config_dir: dir,
        debounce_ms: 50,
        file_system_opts: [backend: :fs_poll, interval: 30],
        reconcile_fun: fn ->
          send(test_pid, :reconciled)
          {:ok, %{}}
        end
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # `FSPoll`'s baseline mtime snapshot is captured asynchronously (its own
    # `:first_check`, scheduled during its `init/1`) — without this, the
    # write below can race ahead of that first snapshot and end up *inside*
    # the baseline instead of showing up as a diff against it.
    Process.sleep(100)
    File.write!(Path.join(dir, "new_file.yaml"), "hello: world\n")

    assert_receive :reconciled, 2_000
  end

  test "VIGIL_WATCHER_BACKEND=poll forces the portable backend with no opts override" do
    System.put_env("VIGIL_WATCHER_BACKEND", "poll")
    System.put_env("VIGIL_WATCHER_POLL_INTERVAL_MS", "30")

    on_exit(fn ->
      System.delete_env("VIGIL_WATCHER_BACKEND")
      System.delete_env("VIGIL_WATCHER_POLL_INTERVAL_MS")
    end)

    test_pid = self()

    dir =
      Path.join(System.tmp_dir!(), "vigil-watcher-envvar-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # No `:file_system_opts` passed at all — if the env var weren't honored,
    # this would fall back to the platform's native backend, which fails to
    # start in this sandbox (no `inotify-tools`) and the Watcher would come
    # up degraded, never detecting the write below.
    {:ok, pid} =
      Watcher.start_link(
        config_dir: dir,
        debounce_ms: 50,
        reconcile_fun: fn ->
          send(test_pid, :reconciled)
          {:ok, %{}}
        end
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    Process.sleep(100)
    File.write!(Path.join(dir, "new_file.yaml"), "hello: world\n")

    assert_receive :reconciled, 2_000
  end

  # ---------------------------------------------------------------------
  # End-to-end tests through the real Vigil.Runtime.Supervisor tree: a real
  # `file_system` backend (portable `:fs_poll`, for the same reason as above)
  # watches a real tmp directory, and a real edit on disk drives the whole
  # flow (Watcher → Reconciler → diff → apply).
  # ---------------------------------------------------------------------

  describe "end-to-end through Vigil.Runtime.Supervisor" do
    setup do
      TestSupport.put_provider(OkProvider)

      dir = Path.join(System.tmp_dir!(), "vigil-watcher-#{System.unique_integer([:positive])}")
      File.cp_r!(@base, dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, dir: dir}
    end

    defp watcher_opts do
      [debounce_ms: 100, file_system_opts: [backend: :fs_poll, interval: 30]]
    end

    test "a valid change on disk triggers an automatic reload after debounce", %{dir: dir} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:vigil, :reload, :completed],
          [:vigil, :runtime, :cycle, :finished]
        ])

      start_supervised!({Vigil.Runtime.Supervisor, config_dir: dir, watcher: watcher_opts()})
      assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000
      assert :error = worker_pid("itub4")

      File.cp!(@itub4_fixture, Path.join(dir, "assets/itub4.yaml"))

      assert_receive {[:vigil, :reload, :completed], ^ref, _, %{applied: applied}}, 3_000
      assert "itub4" in applied.started
      assert eventually(fn -> match?({:ok, _pid}, worker_pid("itub4")) end)
    end

    test "an invalid change on disk is rejected, the watcher survives, workers are untouched", %{
      dir: dir
    } do
      ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :reload, :rejected]])

      start_supervised!({Vigil.Runtime.Supervisor, config_dir: dir, watcher: watcher_opts()})
      assert eventually(fn -> match?({:ok, _pid}, worker_pid("petr4")) end)
      {:ok, pid_before} = worker_pid("petr4")

      petr4_path = Path.join(dir, "assets/petr4.yaml")

      File.write!(petr4_path, """
      apiVersion: v1
      kind: Asset
      metadata:
        name: petr4
      spec:
        provider: yahoo
      """)

      # `:fs_poll` detects a modification by comparing `File.stat!/1` mtimes,
      # which Erlang reports at 1-second resolution — a rewrite of an
      # *existing* path within the same wall-clock second as its previous
      # mtime is otherwise invisible to it (unlike adding a brand-new path,
      # detected by presence alone, see the "valid change" test above).
      # Forcing the mtime forward sidesteps that granularity instead of
      # depending on the write happening to land in a different second.
      File.touch!(petr4_path, {{2099, 1, 1}, {0, 0, 0}})

      assert_receive {[:vigil, :reload, :rejected], ^ref, _, _}, 3_000

      watcher_pid = Process.whereis(Vigil.Runtime.Watcher)
      assert is_pid(watcher_pid)
      assert Process.alive?(watcher_pid)

      assert {:ok, ^pid_before} = worker_pid("petr4")
      assert {:ok, _pid} = worker_pid("vale3")
    end
  end
end
