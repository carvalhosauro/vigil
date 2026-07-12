defmodule Vigil.Core.ConfigDiff do
  @moduledoc """
  Pure diff engine over two resolved `%Config{}` snapshots (RFC-0006 §10).

  Compares desired (disk) against actual (running) state per resource kind —
  Asset, Rule, Notifier — and classifies each by name as `added`, `removed`,
  `changed`, or `unchanged`. Only struct equality is used for `changed`
  (defaults are already resolved into `asset.interval`/`rule.cooldown` by
  `Vigil.Core.Config.validate/1`, so a Defaults-only edit surfaces here for
  free as changed assets/rules — RFC-0006 §10, DEC-004).
  """

  alias Vigil.Core.Config

  @type resource_diff :: %{
          added: [String.t()],
          removed: [String.t()],
          changed: [String.t()],
          unchanged: [String.t()]
        }

  @type t :: %{
          assets: resource_diff(),
          rules: resource_diff(),
          notifiers: resource_diff()
        }

  @doc """
  Diffs `desired` against `actual`, one `resource_diff/0` per resource kind.
  """
  @spec diff(Config.t(), Config.t()) :: t()
  def diff(%Config{} = desired, %Config{} = actual) do
    %{
      assets: diff_resources(desired.assets, actual.assets),
      rules: diff_resources(desired.rules, actual.rules),
      notifiers: diff_resources(desired.notifiers, actual.notifiers)
    }
  end

  @spec diff_resources(%{String.t() => term()}, %{String.t() => term()}) :: resource_diff()
  defp diff_resources(desired, actual) do
    desired_names = desired |> Map.keys() |> MapSet.new()
    actual_names = actual |> Map.keys() |> MapSet.new()

    added = desired_names |> MapSet.difference(actual_names) |> Enum.sort()
    removed = actual_names |> MapSet.difference(desired_names) |> Enum.sort()
    common = MapSet.intersection(desired_names, actual_names)

    {changed, unchanged} =
      Enum.reduce(common, {[], []}, fn name, {changed, unchanged} ->
        if Map.fetch!(desired, name) == Map.fetch!(actual, name) do
          {changed, [name | unchanged]}
        else
          {[name | changed], unchanged}
        end
      end)

    %{
      added: added,
      removed: removed,
      changed: Enum.sort(changed),
      unchanged: Enum.sort(unchanged)
    }
  end
end
