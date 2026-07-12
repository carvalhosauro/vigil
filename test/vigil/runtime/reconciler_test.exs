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

  test "apply is best-effort: a start_child failure for one asset does not abort the reload" do
    start_runtime()

    # A decoy process registered under the incoming asset's name makes the
    # `:via` name collide, so `DynamicSupervisor.start_child/2` returns
    # `{:error, {:already_started, _pid}}` for it — the other resource
    # classifications must still be reported (RFC-0006: best-effort apply).
    decoy =
      spawn(fn -> Registry.register(@registry, "itub4", nil) && Process.sleep(:infinity) end)

    on_exit(fn -> Process.exit(decoy, :kill) end)

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@added)

    assert diff.assets.added == ["itub4"]
    assert applied.started == []
    assert [{"itub4", :start, _reason}] = applied.failed
  end

  test "apply is best-effort: removing an asset whose worker already vanished is a no-op" do
    start_runtime()
    terminate_and_deregister("vale3")

    assert {:ok, %{diff: diff, applied: applied}} = Reconciler.reconcile(@removed)

    assert diff.assets.removed == ["vale3"]
    assert applied.stopped == ["vale3"]
    assert applied.failed == []
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
