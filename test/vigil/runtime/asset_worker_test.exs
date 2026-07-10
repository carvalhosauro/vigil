defmodule Vigil.Runtime.AssetWorkerTest do
  use ExUnit.Case, async: false

  alias Vigil.Core.Config.{Asset, Rule}
  alias Vigil.Core.MarketSnapshot
  alias Vigil.Runtime.AssetWorker

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

  defmodule CrashProvider do
    def fetch(_asset), do: raise("unclassifiable fault")
  end

  defmodule SlowProvider do
    def fetch(_asset) do
      Process.sleep(:infinity)
    end
  end

  setup do
    start_supervised!({Task.Supervisor, name: __MODULE__.CycleSup})
    start_supervised!({Task.Supervisor, name: __MODULE__.DispatchSup})
    :ok
  end

  defp asset, do: %Asset{name: "petr4", symbol: "PETR4.SA", provider: "yahoo", interval: "1s"}

  defp rule do
    %Rule{
      name: "breakout",
      asset: "petr4",
      condition: %{field: :price, op: :gt, value: 40},
      actions: ["telegram"],
      cooldown: "5m"
    }
  end

  defp start_worker(provider) do
    Application.put_env(:vigil, :providers, %{"yahoo" => provider})
    on_exit(fn -> Application.delete_env(:vigil, :providers) end)

    start_supervised!(
      {AssetWorker,
       asset: asset(),
       rules: [rule()],
       cycle_task_supervisor: __MODULE__.CycleSup,
       dispatch_task_supervisor: __MODULE__.DispatchSup},
      restart: :temporary
    )
  end

  test "runs a cycle on start and stores the advanced state" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :finished]])

    pid = start_worker(OkProvider)

    assert_receive {[:vigil, :runtime, :cycle, :finished], ^ref, _, %{asset: "petr4"}}, 2_000

    state = AssetWorker.state(pid)
    assert state.vigil_state.previous_snapshot.price == 40.12
  end

  test "skips the tick while a cycle is in flight (DEC-001)" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :scheduler, :cycle, :skipped]])

    pid = start_worker(SlowProvider)

    # the first cycle hangs; force the next tick immediately
    send(pid, :tick)

    assert_receive {[:vigil, :scheduler, :cycle, :skipped], ^ref, _, %{asset: "petr4"}}, 2_000
  end

  test "a cycle fault crashes the worker (DEC-006)" do
    Process.flag(:trap_exit, false)
    pid = start_worker(CrashProvider)
    monitor = Process.monitor(pid)

    assert_receive {:DOWN, ^monitor, :process, ^pid, {:cycle_fault, _reason}}, 2_000
  end

  test "the timeout ceiling kills the cycle and records a failed cycle (DEC-012)" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :cycle, :failed]])

    pid = start_worker(SlowProvider)
    %{cycle: %{ref: task_ref}} = AssetWorker.state(pid)

    # do not wait 60s: inject the timeout message the timer would deliver
    send(pid, {:cycle_timeout, task_ref})

    assert_receive {[:vigil, :runtime, :cycle, :failed], ^ref, _,
                    %{asset: "petr4", reason: :timeout_ceiling}},
                   2_000

    state = AssetWorker.state(pid)
    assert state.cycle == nil
    assert state.vigil_state.health.consecutive_failures == 1
  end
end
