defmodule Vigil.Runtime.Cycle do
  @moduledoc """
  Executes one monitoring cycle (RFC-0015 §7). The sequence never reorders
  (DEC-003):

    read state → fetch (with retry §10) → build Context → evaluate →
    dispatch (policy-gated, §12) → write state

  A cycle that cannot fetch still advances health state and emits its failure
  (DEC-007). All effects are injected, so the module is testable without
  processes; the AssetWorker runs it inside a monitored Task.
  """

  alias Vigil.Adapters.Provider.Error
  alias Vigil.Core.Config.{Asset, Rule}
  alias Vigil.Core.{Context, NotificationPolicy, RuleEngine, State}
  alias Vigil.Runtime.{CycleReport, Events, Retry}

  @online_threshold 5

  @type input :: %{
          required(:asset) => Asset.t(),
          required(:rules) => [Rule.t()],
          required(:state) => State.t(),
          required(:deadline) => integer(),
          required(:fetch) => (Asset.t() -> {:ok, struct()} | {:error, Error.t()}),
          required(:dispatch) => (Rule.t(), Context.t() -> :ok),
          optional(:now_fun) => (-> DateTime.t()),
          optional(:monotonic_fun) => (-> integer()),
          optional(:sleep_fun) => (pos_integer() -> :ok)
        }

  @spec run(input()) :: {CycleReport.t(), State.t()}
  def run(input) do
    input = with_defaults(input)
    Events.emit([:runtime, :cycle, :started], %{}, %{asset: input.asset.name})

    case fetch_with_retry(input, 1) do
      {:ok, snapshot, attempts} -> succeed(input, snapshot, attempts)
      {:error, error, attempts} -> fail(input, error, attempts)
    end
  end

  defp with_defaults(input) do
    Map.merge(
      %{
        now_fun: &DateTime.utc_now/0,
        monotonic_fun: fn -> System.monotonic_time(:millisecond) end,
        sleep_fun: &Process.sleep/1
      },
      input
    )
  end

  defp fetch_with_retry(input, attempt) do
    Events.emit([:provider, :request, :started], %{}, request_meta(input))

    case input.fetch.(input.asset) do
      {:ok, snapshot} ->
        Events.emit([:provider, :request, :finished], %{attempts: attempt}, request_meta(input))
        {:ok, snapshot, attempt}

      {:error, %Error{} = error} ->
        Events.emit(
          [:provider, :request, :failed],
          %{attempts: attempt},
          Map.put(request_meta(input), :category, error.category)
        )

        remaining = input.deadline - input.monotonic_fun.()

        case Retry.next(error, attempt, remaining) do
          {:retry, delay} ->
            input.sleep_fun.(delay)
            fetch_with_retry(input, attempt + 1)

          :halt ->
            {:error, error, attempt}
        end
    end
  end

  defp succeed(input, snapshot, attempts) do
    state = input.state

    prepared =
      State.prepare_cycle(state, %{
        snapshot: snapshot,
        asset: input.asset.name,
        provider: input.asset.provider,
        market_open: snapshot.market_open,
        provider_online: state.health.consecutive_failures < @online_threshold,
        polling_interval: input.asset.interval
      })

    context = Context.build(snapshot, prepared.context_opts)

    case RuleEngine.run(core_rules(input.rules), context, previous: prepared.previous_context) do
      {:ok, triggered} ->
        dispatch_and_advance(input, snapshot, context, triggered, attempts)

      {:error, reason} ->
        # A rule that cannot be evaluated is a configuration fault, not an
        # expected failure — crash the cycle task (RFC-0015 DEC-006).
        raise "rule evaluation fault: #{inspect(reason)}"
    end
  end

  defp dispatch_and_advance(input, snapshot, context, triggered, attempts) do
    now = input.now_fun.()
    triggered_names = MapSet.new(triggered, & &1.name)

    decisions =
      Enum.map(input.rules, fn rule ->
        decision =
          NotificationPolicy.decide(%{
            satisfied: MapSet.member?(triggered_names, rule.name),
            previous: input.state.rules[rule.name],
            notification: input.state.notifications[rule.name],
            cooldown: rule.cooldown,
            now: now
          })

        {rule, decision}
      end)

    state =
      Enum.reduce(decisions, input.state, fn
        {rule, :notify}, acc ->
          input.dispatch.(rule, context)
          State.record_notification(acc, rule.name, now)

        {_rule, _other}, acc ->
          acc
      end)

    rule_results = Map.new(input.rules, &{&1.name, MapSet.member?(triggered_names, &1.name)})

    state =
      State.advance(state, %{
        fetch_outcome: :ok,
        rule_results: rule_results,
        snapshot: snapshot,
        runtime: context.runtime
      })

    report = %CycleReport{
      asset: input.asset.name,
      outcome: :ok,
      attempts: attempts,
      triggered: Enum.map(triggered, & &1.name),
      notified: for({rule, :notify} <- decisions, do: rule.name),
      suppressed: for({rule, {:suppress, _}} <- decisions, do: rule.name)
    }

    Events.emit(
      [:runtime, :cycle, :finished],
      %{attempts: attempts, triggered: length(report.triggered)},
      %{asset: input.asset.name}
    )

    {report, state}
  end

  defp fail(input, error, attempts) do
    state = State.advance(input.state, %{fetch_outcome: :error, rule_results: %{}})

    Events.emit(
      [:runtime, :cycle, :failed],
      %{attempts: attempts, consecutive_failures: state.health.consecutive_failures},
      %{asset: input.asset.name, category: error.category}
    )

    report = %CycleReport{
      asset: input.asset.name,
      outcome: :failed,
      attempts: attempts,
      error: error
    }

    {report, state}
  end

  defp request_meta(input),
    do: %{provider: input.asset.provider, asset: input.asset.name, symbol: input.asset.symbol}

  # RuleEngine consumes Vigil.Core.Rule; config rules carry the same fields
  # plus cooldown, which is policy, not evaluation.
  defp core_rules(rules) do
    Enum.map(rules, fn %Rule{} = rule ->
      %Vigil.Core.Rule{
        name: rule.name,
        asset: rule.asset,
        condition: rule.condition,
        actions: rule.actions
      }
    end)
  end
end
