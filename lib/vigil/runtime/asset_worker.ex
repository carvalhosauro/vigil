defmodule Vigil.Runtime.AssetWorker do
  @moduledoc """
  One supervised worker per Asset (RFC-0015 §8, DEC-002): owns the schedule,
  the per-Asset state and cycle execution.

  Each cycle runs as a monitored Task so the worker stays responsive:
  overlapping ticks are skipped, never queued (DEC-001); a cycle exceeding the
  60s ceiling is killed and recorded as a failed cycle (DEC-012); an
  unclassifiable fault inside the cycle crashes the worker, which its
  supervisor restarts with a clean state (DEC-006, RFC-0012 §12).

  Scheduling is drift-free: the next tick is measured from the intended tick,
  not from the end of the cycle (RFC-0005 §10). No jitter in V1.
  """

  use GenServer, restart: :transient

  alias Vigil.Adapters.Notifier
  alias Vigil.Adapters.Provider
  alias Vigil.Core.{Duration, State}
  alias Vigil.Runtime.{Cycle, Events, Retry}

  @cycle_ceiling_ms 60_000

  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc false
  @spec state(GenServer.server()) :: map()
  def state(server), do: GenServer.call(server, :state)

  @impl GenServer
  def init(opts) do
    asset = Keyword.fetch!(opts, :asset)
    {:ok, interval_ms} = Duration.to_ms(asset.interval)

    state = %{
      asset: asset,
      rules: Keyword.fetch!(opts, :rules),
      channel_configs: Keyword.get(opts, :channel_configs, %{}),
      cycle_task_supervisor: Keyword.fetch!(opts, :cycle_task_supervisor),
      dispatch_task_supervisor: Keyword.fetch!(opts, :dispatch_task_supervisor),
      interval_ms: interval_ms,
      vigil_state: State.initial(),
      cycle: nil,
      timeout_ref: nil,
      next_tick_at: System.monotonic_time(:millisecond)
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_info(:tick, state) do
    state = schedule_next_tick(state)
    Events.emit([:scheduler, :cycle, :started], %{}, %{asset: state.asset.name})

    if state.cycle do
      Events.emit([:scheduler, :cycle, :skipped], %{}, %{asset: state.asset.name})
      {:noreply, state}
    else
      {:noreply, start_cycle(state)}
    end
  end

  def handle_info({ref, {_report, vigil_state}}, %{cycle: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel_timeout(state.timeout_ref)
    {:noreply, %{state | vigil_state: vigil_state, cycle: nil, timeout_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{cycle: %{ref: ref}} = state) do
    # Unclassifiable fault inside the cycle: the worker crashes and is
    # restarted by its supervisor (RFC-0015 DEC-006).
    {:stop, {:cycle_fault, reason}, state}
  end

  def handle_info({:cycle_timeout, ref}, %{cycle: %{ref: ref, pid: pid}} = state) do
    # Drain: if the task result is already in the mailbox (arrived just before
    # this timeout message was processed), prefer it over declaring a timeout
    # failure — prevents a lost cooldown write and a spurious health-counter
    # increment (RFC-0015 DEC-008).
    receive do
      {^ref, {_report, vigil_state}} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | vigil_state: vigil_state, cycle: nil, timeout_ref: nil}}
    after
      0 ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])

        vigil_state =
          State.advance(state.vigil_state, %{fetch_outcome: :error, rule_results: %{}})

        Events.emit(
          [:runtime, :cycle, :failed],
          %{consecutive_failures: vigil_state.health.consecutive_failures},
          %{asset: state.asset.name, reason: :timeout_ceiling}
        )

        {:noreply, %{state | vigil_state: vigil_state, cycle: nil, timeout_ref: nil}}
    end
  end

  # Late replies from a killed cycle task, stale timeout timers, dispatch
  # task results — ignored by design.
  def handle_info(_message, state), do: {:noreply, state}

  defp start_cycle(state) do
    Events.emit([:scheduler, :cycle, :triggered], %{}, %{asset: state.asset.name})

    {:ok, provider} = Provider.Registry.fetch(state.asset.provider)
    deadline = min(state.next_tick_at, System.monotonic_time(:millisecond) + @cycle_ceiling_ms)
    dispatch = build_dispatch(state)

    input = %{
      asset: state.asset,
      rules: state.rules,
      state: state.vigil_state,
      deadline: deadline,
      fetch: &provider.fetch/1,
      dispatch: dispatch
    }

    task = Task.Supervisor.async_nolink(state.cycle_task_supervisor, Cycle, :run, [input])
    timeout_ref = Process.send_after(self(), {:cycle_timeout, task.ref}, @cycle_ceiling_ms)

    %{state | cycle: %{ref: task.ref, pid: task.pid}, timeout_ref: timeout_ref}
  end

  # Delivery is asynchronous and never blocks the cycle (RFC-0015 §12,
  # DEC-008). Delivery retry runs inside the unlinked dispatch task, bounded
  # by the rule's cooldown window (RFC-0015 §12, RFC-0007 §11).
  defp build_dispatch(state) do
    dispatch_supervisor = state.dispatch_task_supervisor
    asset_name = state.asset.name
    channel_configs = state.channel_configs

    fn rule, context ->
      Enum.each(rule.actions, fn action ->
        case Notifier.Registry.fetch(action) do
          {:ok, notifier} ->
            channel_config = Map.get(channel_configs, action)

            case Task.Supervisor.start_child(dispatch_supervisor, fn ->
                   deliver(notifier, rule, context, channel_config, asset_name)
                 end) do
              {:ok, _pid} ->
                :ok

              {:error, reason} ->
                Events.emit([:notification, :failed], %{attempts: 0}, %{
                  asset: asset_name,
                  rule: rule.name,
                  reason: {:dispatch_start_failed, reason}
                })
            end

          :error ->
            Events.emit([:notification, :failed], %{attempts: 0}, %{
              asset: asset_name,
              rule: rule.name,
              reason: {:unknown_notifier, action}
            })
        end
      end)

      :ok
    end
  end

  defp deliver(notifier, rule, context, channel_config, asset_name) do
    budget_ms =
      case Duration.to_ms(rule.cooldown) do
        {:ok, ms} -> ms
        :error -> 0
      end

    delivery = %{
      notifier: notifier,
      rule: rule,
      context: context,
      channel_config: channel_config,
      asset_name: asset_name,
      deadline: System.monotonic_time(:millisecond) + budget_ms
    }

    deliver_with_retry(delivery, 1)
  end

  defp deliver_with_retry(delivery, attempt) do
    case delivery.notifier.notify(delivery.rule, delivery.context, delivery.channel_config) do
      {:ok, sent} ->
        Events.emit([:notification, :sent], %{}, %{
          asset: delivery.asset_name,
          rule: delivery.rule.name,
          delivery: sent
        })

      {:error, %Notifier.Error{} = error} ->
        remaining_ms = delivery.deadline - System.monotonic_time(:millisecond)

        case Retry.next(error, attempt, remaining_ms) do
          {:retry, delay} ->
            Process.sleep(delay)
            deliver_with_retry(delivery, attempt + 1)

          :halt ->
            emit_delivery_failed(delivery, attempt, error)
        end

      {:error, reason} ->
        emit_delivery_failed(delivery, attempt, reason)
    end
  end

  defp emit_delivery_failed(delivery, attempt, reason) do
    Events.emit([:notification, :failed], %{attempts: attempt}, %{
      asset: delivery.asset_name,
      rule: delivery.rule.name,
      reason: reason
    })
  end

  defp schedule_next_tick(state) do
    next = state.next_tick_at + state.interval_ms
    delay = max(next - System.monotonic_time(:millisecond), 0)
    Process.send_after(self(), :tick, delay)
    %{state | next_tick_at: next}
  end

  defp cancel_timeout(nil), do: :ok
  defp cancel_timeout(ref), do: Process.cancel_timer(ref)
end
