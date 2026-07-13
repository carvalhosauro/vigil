defmodule Vigil.Runtime.ReconcilerTest do
  use ExUnit.Case, async: false

  alias Vigil.Adapters.ConfigLoader
  alias Vigil.Core.MarketSnapshot
  alias Vigil.Runtime.{AssetWorker, Reconciler, WorkersSupervisor}

  @registry Vigil.Runtime.WorkerRegistry
  @base "test/fixtures/reload/base"
  @added "test/fixtures/reload/added"
  @removed "test/fixtures/reload/removed"
  @changed "test/fixtures/reload/changed"
  @rule_only "test/fixtures/reload/rule_only"
  @notifier_only "test/fixtures/reload/notifier_only"
  @invalid "test/fixtures/reload/invalid"

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

  setup do
    System.put_env("TELEGRAM_TOKEN", "tok")
    System.put_env("CHAT_ID", "123")
    Application.put_env(:vigil, :providers, %{"yahoo" => OkProvider})

    on_exit(fn ->
      System.delete_env("TELEGRAM_TOKEN")
      System.delete_env("CHAT_ID")
      Application.delete_env(:vigil, :providers)
    end)

    :ok
  end

  # Boots the full runtime tree (Registry, WorkersSupervisor, Reconciler,
  # Control) against `@base` so a Reconciler-driven reload exercises the real
  # DynamicSupervisor + Registry wiring, not a hand-rolled stand-in.
  defp start_runtime(config_dir \\ @base) do
    start_supervised!({Vigil.Runtime.Supervisor, config_dir: config_dir})
    :ok
  end

  defp worker_pid(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  # Terminates the worker and waits for the Registry to reflect it — Registry
  # unregisters via its own monitor on the process, a race independent of any
  # monitor the test itself holds on the same pid.
  defp terminate_and_deregister(name) do
    {:ok, pid} = worker_pid(name)
    :ok = DynamicSupervisor.terminate_child(WorkersSupervisor, pid)
    assert eventually(fn -> worker_pid(name) == :error end)
    pid
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  test "asset added: reconcile starts a new worker" do
    start_runtime()
    assert :error = worker_pid("itub4")

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@added)

    assert diff.assets.added == ["itub4"]
    assert applied.started == ["itub4"]
    assert {:ok, pid} = worker_pid("itub4")
    assert AssetWorker.state(pid).asset.name == "itub4"
  end

  test "restart re-syncs from the current on-disk config, not the boot config" do
    # A mutable copy of the base config so disk can change after boot.
    dir = Path.join(System.tmp_dir!(), "vigil_resync_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(@base, dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_runtime(dir)
    assert {:ok, _pid} = worker_pid("petr4")
    assert :error = worker_pid("itub4")

    # Change disk after boot: add itub4 (absent from the boot config).
    File.cp!(Path.join(@added, "assets/itub4.yaml"), Path.join(dir, "assets/itub4.yaml"))

    # Crash the WorkersSupervisor: :rest_for_one restarts it (empty) and the
    # Reconciler. An init that trusted the boot config would never know about
    # itub4; loading from disk picks up the on-disk change (DEC-001).
    Process.exit(Process.whereis(WorkersSupervisor), :kill)

    assert eventually(fn -> match?({:ok, _pid}, worker_pid("itub4")) end)
    assert {:ok, _pid} = worker_pid("petr4")
  end

  test "restart with an invalid on-disk config comes up empty instead of crash-looping" do
    dir = Path.join(System.tmp_dir!(), "vigil_bad_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(@base, dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_runtime(dir)
    assert {:ok, _pid} = worker_pid("petr4")

    # Break the config on disk after boot (asset missing its required symbol).
    File.write!(Path.join(dir, "assets/petr4.yaml"), """
    apiVersion: v1
    kind: Asset
    metadata:
      name: petr4
    spec:
      provider: yahoo
    """)

    Process.exit(Process.whereis(WorkersSupervisor), :kill)

    # The Reconciler re-inits, the disk load fails, so it comes up empty (no
    # workers) — but the runtime tree stays alive rather than crash-looping.
    assert eventually(fn -> worker_pid("petr4") == :error end)
    assert eventually(fn -> is_pid(Process.whereis(Reconciler)) end)
  end

  test "asset removed: reconcile stops the worker" do
    start_runtime()
    assert {:ok, _pid} = worker_pid("vale3")

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@removed)

    assert diff.assets.removed == ["vale3"]
    assert applied.stopped == ["vale3"]
    # Registry unregisters via its own monitor on the terminated worker, which
    # completes independently of (and possibly slightly after) the
    # synchronous `DynamicSupervisor.terminate_child/2` call inside `reconcile`.
    assert eventually(fn -> worker_pid("vale3") == :error end)
  end

  test "asset changed: reconcile restarts the worker with fresh state" do
    start_runtime()
    assert {:ok, pid_before} = worker_pid("petr4")

    # Give the worker some accumulated state before the restart.
    :sys.replace_state(pid_before, fn state ->
      health = %{state.vigil_state.health | consecutive_failures: 2}
      %{state | vigil_state: %{state.vigil_state | health: health}}
    end)

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@changed)

    assert diff.assets.changed == ["petr4"]
    assert applied.restarted == ["petr4"]

    assert {:ok, pid_after} = worker_pid("petr4")
    assert pid_after != pid_before

    new_state = AssetWorker.state(pid_after)
    assert new_state.asset.interval == "2s"
    assert new_state.vigil_state.health.consecutive_failures == 0
  end

  test "rule-only change: worker is updated in place, same pid, new rules" do
    start_runtime()
    assert {:ok, pid_before} = worker_pid("petr4")

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@rule_only)

    assert diff.assets.unchanged == ["petr4", "vale3"]
    assert diff.rules.changed == ["breakout"]
    assert applied.updated == ["petr4"]
    assert "vale3" in applied.unchanged

    assert {:ok, pid_after} = worker_pid("petr4")
    assert pid_after == pid_before

    assert [%{cooldown: "15m"}] = AssetWorker.state(pid_after).rules
  end

  test "notifier-only change: workers referencing it are updated in place" do
    start_runtime()
    assert {:ok, pid_before} = worker_pid("petr4")

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@notifier_only)

    assert diff.notifiers.added == ["telegram2"]
    assert diff.assets.unchanged == ["petr4", "vale3"]
    assert "petr4" in applied.updated
    assert "vale3" in applied.updated

    assert {:ok, pid_after} = worker_pid("petr4")
    assert pid_after == pid_before
    assert Map.has_key?(AssetWorker.state(pid_after).channel_configs, "telegram2")
  end

  test "invalid config: reload is rejected and the current config is preserved" do
    start_runtime()
    assert {:ok, pid_before} = worker_pid("petr4")

    assert {:error, _reason} = Reconciler.reconcile(@invalid)

    # Current config untouched: no worker was started/stopped/restarted.
    assert {:ok, pid_after} = worker_pid("petr4")
    assert pid_after == pid_before
    assert {:ok, _pid} = worker_pid("vale3")

    %{config: config} = :sys.get_state(Reconciler)
    assert {:ok, expected} = ConfigLoader.load(@base)
    assert config == expected
  end

  test "reconcile/0 reloads from the held config_dir" do
    start_runtime()

    assert {:ok, %{diff: diff}} = Reconciler.reconcile()
    assert diff.assets.unchanged == ["petr4", "vale3"]
  end

  test "reload.started/completed events are emitted on a successful reload" do
    start_runtime()

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vigil, :reload, :started],
        [:vigil, :reload, :completed]
      ])

    assert {:ok, _summary} = Reconciler.reconcile(@added)

    assert_received {[:vigil, :reload, :started], ^ref, _, %{config_dir: @added}}
    assert_received {[:vigil, :reload, :completed], ^ref, _, %{diff: _diff, applied: _applied}}
  end

  test "reload.rejected is emitted on a validation failure" do
    start_runtime()

    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :reload, :rejected]])

    assert {:error, _reason} = Reconciler.reconcile(@invalid)

    assert_received {[:vigil, :reload, :rejected], ^ref, _, %{reason: _reason}}
  end

  test "a name collision with a non-worker process is a real start failure" do
    start_runtime()

    # A decoy occupying the incoming asset's `:via` name that is NOT a
    # supervised `AssetWorker` — `actual_from_runtime/0` only sees real
    # `WorkersSupervisor` children, so this asset still diffs as `added`, and
    # `DynamicSupervisor.start_child/2` genuinely collides with it. This must
    # surface as a failure, not be papered over (RFC-0006: best-effort apply
    # reports failures instead of masking them).
    decoy =
      spawn(fn -> Registry.register(@registry, "itub4", nil) && Process.sleep(:infinity) end)

    on_exit(fn -> Process.exit(decoy, :kill) end)

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@added)

    assert diff.assets.added == ["itub4"]
    assert applied.started == []
    assert [{"itub4", :start, _reason}] = applied.failed
  end

  test "a Reconciler-only crash diffs against the live workers, not an empty config" do
    start_runtime()
    assert {:ok, petr4_before} = worker_pid("petr4")
    assert {:ok, vale3_before} = worker_pid("vale3")

    # Kill only the Reconciler, not WorkersSupervisor: it sits after
    # WorkersSupervisor in the `:rest_for_one` tree, so `:rest_for_one`
    # restarts Reconciler (and Control, after it) but leaves the running
    # AssetWorkers alone. `init/1` now reconstructs `actual` from those
    # survivors (`actual_from_runtime/0`), so they diff as `unchanged`
    # against the freshly reloaded desired config — no `added`, no
    # `already_started` collision, no restart, same pid.
    reconciler_pid = Process.whereis(Reconciler)
    ref = Process.monitor(reconciler_pid)
    Process.exit(reconciler_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^reconciler_pid, :killed}

    assert eventually(fn ->
             new_pid = Process.whereis(Reconciler)
             is_pid(new_pid) and new_pid != reconciler_pid
           end)

    assert {:ok, ^petr4_before} = worker_pid("petr4")
    assert {:ok, ^vale3_before} = worker_pid("vale3")

    # The reconciled Reconciler's own state is already back in sync with
    # disk, so a subsequent manual reload sees no further changes.
    assert {:ok, %{diff: diff}} = Reconciler.reconcile()
    assert diff.assets.unchanged == ["petr4", "vale3"]
  end

  test "a Reconciler-only crash detects an asset removed from disk while it was down" do
    dir =
      Path.join(System.tmp_dir!(), "vigil_removed_live_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.cp_r!(@base, dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_runtime(dir)
    assert {:ok, _pid} = worker_pid("petr4")
    assert {:ok, _pid} = worker_pid("vale3")

    # Before this fix, `init/1` always diffed against an empty actual config,
    # so a removal that happened purely on disk while the Reconciler was down
    # was never detected on restart — the worker just kept running forever.
    File.rm!(Path.join(dir, "assets/vale3.yaml"))

    reconciler_pid = Process.whereis(Reconciler)
    ref = Process.monitor(reconciler_pid)
    Process.exit(reconciler_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^reconciler_pid, :killed}

    assert eventually(fn -> worker_pid("vale3") == :error end)
    assert {:ok, _pid} = worker_pid("petr4")
  end

  describe "await_deregistered/1 (used by restart_worker/2 to close the deregister race)" do
    test "polls until the Registry clears the name, then succeeds" do
      start_runtime()
      name = "await-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      # Holds the name just long enough (well under the 1s timeout, comfortably
      # over the 10ms poll interval) to force at least one "still registered,
      # sleep, retry" loop — deterministic, unlike relying on the real
      # stop/start race actually reproducing within a single test run. The
      # `:registered` handshake avoids a second race: without it,
      # `await_deregistered/1` could run its first check before this process
      # has registered at all, wrongly seeing the name as already free.
      spawn(fn ->
        Registry.register(@registry, name, nil)
        send(test_pid, :registered)
        Process.sleep(30)
      end)

      assert_receive :registered
      assert Reconciler.await_deregistered(name) == :ok
    end

    test "gives up after the bounded timeout if the name is never freed" do
      start_runtime()
      name = "await-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      decoy =
        spawn(fn ->
          Registry.register(@registry, name, nil)
          send(test_pid, :registered)
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(decoy, :kill) end)
      assert_receive :registered

      assert Reconciler.await_deregistered(name) == {:error, :deregister_timeout}
    end
  end

  describe "fetch_worker_state/1 (used by actual_from_runtime/0 on init)" do
    test "a dead pid is skipped instead of crashing `init/1`" do
      dead_pid = spawn(fn -> :ok end)
      # Ensure the process has actually exited before calling — `GenServer.call`
      # to an already-dead pid fails fast with `:noproc` (no 5s timeout wait).
      assert eventually(fn -> not Process.alive?(dead_pid) end)

      assert Reconciler.fetch_worker_state(
               {:undefined, dead_pid, :worker, [Vigil.Runtime.AssetWorker]}
             ) ==
               []
    end

    test "a non-pid child (e.g. :restarting) is skipped instead of crashing `init/1`" do
      assert Reconciler.fetch_worker_state({:undefined, :restarting, :worker, :dynamic}) == []
    end
  end

  test "apply is best-effort: removing an asset whose worker already vanished is a no-op" do
    start_runtime()
    terminate_and_deregister("vale3")

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@removed)

    assert diff.assets.removed == ["vale3"]
    assert applied.stopped == ["vale3"]
    assert applied.failed == []
  end

  test "apply is best-effort: a restart whose stop half genuinely fails is still reported" do
    start_runtime()
    {:ok, real_pid} = worker_pid("petr4")

    # Terminate the real worker for real, then squat its `:via` name with a
    # decoy that is registered but is NOT a child of `WorkersSupervisor`:
    # `DynamicSupervisor.terminate_child/2` then returns `{:error, :not_found}`
    # for it — a genuine (non-`already_started`) failure, distinct from the
    # start-collision case above, exercising `apply_each/3`'s shared
    # failed-accumulation clause (RFC-0006: best-effort apply).
    :ok = DynamicSupervisor.terminate_child(WorkersSupervisor, real_pid)
    assert eventually(fn -> worker_pid("petr4") == :error end)

    decoy =
      spawn(fn -> Registry.register(@registry, "petr4", nil) && Process.sleep(:infinity) end)

    on_exit(fn -> Process.exit(decoy, :kill) end)

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@changed)

    assert diff.assets.changed == ["petr4"]
    assert applied.restarted == []
    assert [{"petr4", :restart, :not_found}] = applied.failed
  end

  test "apply is best-effort: an in-place update for a vanished worker is captured as failed" do
    start_runtime()
    terminate_and_deregister("petr4")

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@rule_only)

    assert diff.assets.unchanged == ["petr4", "vale3"]
    assert applied.updated == []
    assert [{"petr4", :update, :worker_not_found}] = applied.failed
  end

  test "boot performs the initial sync: one worker per asset, no reload events" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vigil, :reload, :started],
        [:vigil, :reload, :completed]
      ])

    start_runtime()

    assert {:ok, _pid} = worker_pid("petr4")
    assert {:ok, _pid} = worker_pid("vale3")
    refute_received {[:vigil, :reload, :started], ^ref, _, _}
    refute_received {[:vigil, :reload, :completed], ^ref, _, _}
  end
end
