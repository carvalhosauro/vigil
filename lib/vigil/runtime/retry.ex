defmodule Vigil.Runtime.Retry do
  @moduledoc """
  In-cycle retry policy (RFC-0015 §10, DEC-004/005).

  Max 3 attempts per cycle; exponential backoff 1s, 2s capped at 30s; the
  budget never crosses the next tick. `timeout`, `network` and `unavailable`
  are retried; `rate_limit` waits only on an explicit provider hint
  (`details[:retry_after_ms]`) that fits the budget (DEC-011); everything else
  fails the cycle immediately.
  """

  alias Vigil.Adapters.Provider.Error

  @max_attempts 3
  @backoff_ms [1_000, 2_000]
  @ceiling_ms 30_000
  @retryable [:timeout, :network, :unavailable]

  @spec next(Error.t(), pos_integer(), integer()) :: {:retry, pos_integer()} | :halt
  def next(_error, attempt, _remaining_ms) when attempt >= @max_attempts, do: :halt

  def next(%Error{category: category}, attempt, remaining_ms) when category in @retryable do
    delay = @backoff_ms |> Enum.at(attempt - 1, @ceiling_ms) |> min(@ceiling_ms)
    if delay <= remaining_ms, do: {:retry, delay}, else: :halt
  end

  def next(%Error{category: :rate_limit, details: details}, _attempt, remaining_ms) do
    case details do
      %{retry_after_ms: ms}
      when is_integer(ms) and ms > 0 and ms <= remaining_ms and ms <= @ceiling_ms ->
        {:retry, ms}

      _ ->
        :halt
    end
  end

  def next(%Error{}, _attempt, _remaining_ms), do: :halt
end
