defmodule Vigil.Core.State do
  @moduledoc """
  Per-asset runtime state that survives across monitoring cycles.

  Pure data and transitions — no IO, no storage. The scheduler (Phase 6)
  holds one `%State{}` per asset. See RFC-0012.

  Cycle protocol:

      prepare_cycle(state, input)  → read state(N-1)
      Context.build + RuleEngine   → evaluate
      advance(state, result)       → write state(N)
  """

  alias Vigil.Core.Context
  alias Vigil.Core.MarketSnapshot
  alias Vigil.Core.State.{Health, NotificationStatus, RuleStatus}

  @enforce_keys [
    :previous_snapshot,
    :prior_snapshot,
    :previous_runtime,
    :health,
    :rules,
    :notifications,
    :windows
  ]
  defstruct previous_snapshot: nil,
            prior_snapshot: nil,
            previous_runtime: %{},
            health: %Health{},
            rules: %{},
            notifications: %{},
            windows: %{}

  @type cycle_input :: %{
          required(:snapshot) => MarketSnapshot.t(),
          required(:asset) => String.t(),
          required(:provider) => String.t(),
          required(:market_open) => boolean(),
          required(:provider_online) => boolean(),
          optional(:polling_interval) => String.t() | nil
        }

  @type advance_input :: %{
          required(:fetch_outcome) => :ok | :error,
          required(:rule_results) => %{String.t() => boolean()},
          optional(:snapshot) => MarketSnapshot.t() | nil,
          optional(:runtime) => map()
        }

  @type t :: %__MODULE__{
          previous_snapshot: MarketSnapshot.t() | nil,
          prior_snapshot: MarketSnapshot.t() | nil,
          previous_runtime: map(),
          health: Health.t(),
          rules: %{String.t() => RuleStatus.t()},
          notifications: %{String.t() => NotificationStatus.t()},
          windows: map()
        }

  @doc "Returns empty state for a newly added asset."
  @spec initial() :: t()
  def initial do
    %__MODULE__{
      previous_snapshot: nil,
      prior_snapshot: nil,
      previous_runtime: %{},
      health: %Health{},
      rules: %{},
      notifications: %{},
      windows: %{}
    }
  end

  @doc """
  Reads state before cycle N.

  Returns `context_opts` for `Context.build/2` and `previous_context` for
  `RuleEngine.run/3` (`previous:` opt).
  """
  @spec prepare_cycle(t(), cycle_input()) :: %{
          context_opts: keyword(),
          previous_context: Context.t() | nil
        }
  def prepare_cycle(%__MODULE__{} = state, cycle_input) do
    asset_opts = [
      asset: cycle_input.asset,
      provider: cycle_input.provider,
      polling_interval: Map.get(cycle_input, :polling_interval)
    ]

    runtime = %{
      market_open: cycle_input.market_open,
      provider_online: cycle_input.provider_online,
      last_update: state.health.last_success,
      consecutive_failures: state.health.consecutive_failures
    }

    context_opts =
      asset_opts ++
        [
          previous_snapshot: state.previous_snapshot,
          runtime: runtime
        ]

    previous_context = build_previous_context(state, asset_opts)

    %{context_opts: context_opts, previous_context: previous_context}
  end

  @doc """
  Advances state after evaluation.

  On `:ok`, stores the snapshot and runtime as the previous cycle data.
  On `:error`, only health counters and rule satisfaction are updated.
  """
  @spec advance(t(), advance_input()) :: t()
  def advance(%__MODULE__{} = state, %{fetch_outcome: :ok} = input) do
    snapshot = Map.fetch!(input, :snapshot)
    runtime = Map.fetch!(input, :runtime)

    %{
      state
      | prior_snapshot: state.previous_snapshot,
        previous_snapshot: snapshot,
        previous_runtime: runtime,
        health: health_on_success(state.health, snapshot),
        rules: update_rules(state.rules, input.rule_results)
    }
  end

  def advance(%__MODULE__{} = state, %{fetch_outcome: :error} = input) do
    %{
      state
      | health: health_on_failure(state.health),
        rules: update_rules(state.rules, input.rule_results)
    }
  end

  @doc "Records that a notification was sent for a rule. Used by Phase 7."
  @spec record_notification(t(), String.t(), DateTime.t()) :: t()
  def record_notification(%__MODULE__{} = state, rule_name, at) do
    notifications =
      Map.update(state.notifications, rule_name, %NotificationStatus{last_notified_at: at}, fn
        %NotificationStatus{} = status -> %{status | last_notified_at: at}
      end)

    %{state | notifications: notifications}
  end

  @spec build_previous_context(t(), keyword()) :: Context.t() | nil
  defp build_previous_context(%__MODULE__{previous_snapshot: nil}, _asset_opts), do: nil

  defp build_previous_context(%__MODULE__{} = state, asset_opts) do
    Context.build(
      state.previous_snapshot,
      asset_opts ++
        [
          runtime: state.previous_runtime,
          previous_snapshot: state.prior_snapshot
        ]
    )
  end

  @spec health_on_success(Health.t(), MarketSnapshot.t()) :: Health.t()
  defp health_on_success(%Health{} = health, snapshot) do
    %{health | consecutive_failures: 0, last_success: snapshot.timestamp}
  end

  @spec health_on_failure(Health.t()) :: Health.t()
  defp health_on_failure(%Health{} = health) do
    %{health | consecutive_failures: health.consecutive_failures + 1}
  end

  @spec update_rules(%{String.t() => RuleStatus.t()}, %{String.t() => boolean()}) :: %{
          String.t() => RuleStatus.t()
        }
  defp update_rules(rules, rule_results) do
    Enum.reduce(rule_results, rules, fn {name, satisfied}, acc ->
      Map.update(acc, name, %RuleStatus{satisfied: satisfied}, fn %RuleStatus{} = status ->
        %{status | satisfied: satisfied}
      end)
    end)
  end
end
