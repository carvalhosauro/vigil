defmodule Vigil.Core.Duration do
  @moduledoc """
  Parses the `duration` config type (`"15s"`, `"5m"`, `"2h"`) into milliseconds.

  See RFC-0003 §8 (intervals) and RFC-0007 §9 (cooldown). Zero is rejected —
  a zero interval or cooldown is always a configuration mistake.
  """

  @re ~r/^(\d+)([smh])$/

  @spec to_ms(String.t()) :: {:ok, pos_integer()} | :error
  def to_ms(value) when is_binary(value) do
    with [_, digits, unit] <- Regex.run(@re, value),
         n when n > 0 <- String.to_integer(digits) do
      {:ok, n * unit_ms(unit)}
    else
      _ -> :error
    end
  end

  defp unit_ms("s"), do: 1_000
  defp unit_ms("m"), do: 60_000
  defp unit_ms("h"), do: 3_600_000
end
