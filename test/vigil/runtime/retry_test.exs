defmodule Vigil.Runtime.RetryTest do
  use ExUnit.Case, async: true

  alias Vigil.Adapters.Provider.Error
  alias Vigil.Runtime.Retry

  defp error(category, details \\ %{}) do
    Error.new(category, %{
      message: "boom",
      provider: "yahoo",
      symbol: "X",
      details: details
    })
  end

  describe "next/3 — retryable categories (RFC-0015 §10)" do
    test "first failure retries after 1s" do
      for category <- [:timeout, :network, :unavailable] do
        assert Retry.next(error(category), 1, 60_000) == {:retry, 1_000}
      end
    end

    test "second failure retries after 2s" do
      assert Retry.next(error(:timeout), 2, 60_000) == {:retry, 2_000}
    end

    test "third failure halts (max 3 attempts)" do
      assert Retry.next(error(:timeout), 3, 60_000) == :halt
    end

    test "halts when the backoff would cross the budget (never past the next tick)" do
      assert Retry.next(error(:timeout), 1, 500) == :halt
    end
  end

  describe "next/3 — rate limit (DEC-011)" do
    test "waits the provider hint when it fits the budget" do
      assert Retry.next(error(:rate_limit, %{retry_after_ms: 3_000}), 1, 60_000) ==
               {:retry, 3_000}
    end

    test "halts without a hint" do
      assert Retry.next(error(:rate_limit), 1, 60_000) == :halt
    end

    test "halts when the hint exceeds the budget" do
      assert Retry.next(error(:rate_limit, %{retry_after_ms: 3_000}), 1, 2_000) == :halt
    end

    test "halts when the hint exceeds the 30s ceiling" do
      assert Retry.next(error(:rate_limit, %{retry_after_ms: 31_000}), 1, 60_000) == :halt
    end
  end

  describe "next/3 — never retried" do
    test "authentication, invalid_response and configuration halt immediately" do
      for category <- [:authentication, :invalid_response, :configuration] do
        assert Retry.next(error(category), 1, 60_000) == :halt
      end
    end
  end
end
