defmodule Vigil.Core.ConfigDiffTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Config
  alias Vigil.Core.Config.{Asset, Defaults, Rule, Telegram}
  alias Vigil.Core.ConfigDiff

  defp asset(name, interval \\ "1s"),
    do: %Asset{name: name, symbol: String.upcase(name), provider: "yahoo", interval: interval}

  defp rule(name, asset_name, cooldown) do
    %Rule{
      name: name,
      asset: asset_name,
      condition: %{field: :price, op: :gt, value: 40},
      actions: ["telegram"],
      cooldown: cooldown
    }
  end

  defp telegram(name, chat_id \\ "${CHAT_ID}"),
    do: %Telegram{name: name, token: "${TELEGRAM_TOKEN}", chat_id: chat_id}

  defp config(opts) do
    %Config{
      assets: Keyword.get(opts, :assets, %{}),
      rules: Keyword.get(opts, :rules, %{}),
      notifiers: Keyword.get(opts, :notifiers, %{}),
      defaults: Keyword.get(opts, :defaults)
    }
  end

  test "an asset only in desired is added" do
    desired = config(assets: %{"petr4" => asset("petr4")})
    actual = config(assets: %{})

    assert %{assets: %{added: ["petr4"], removed: [], changed: [], unchanged: []}} =
             ConfigDiff.diff(desired, actual)
  end

  test "an asset only in actual is removed" do
    desired = config(assets: %{})
    actual = config(assets: %{"petr4" => asset("petr4")})

    assert %{assets: %{added: [], removed: ["petr4"], changed: [], unchanged: []}} =
             ConfigDiff.diff(desired, actual)
  end

  test "an asset with a differing spec is changed" do
    desired = config(assets: %{"petr4" => asset("petr4", "2s")})
    actual = config(assets: %{"petr4" => asset("petr4", "1s")})

    assert %{assets: %{added: [], removed: [], changed: ["petr4"], unchanged: []}} =
             ConfigDiff.diff(desired, actual)
  end

  test "an identical asset is unchanged" do
    desired = config(assets: %{"petr4" => asset("petr4")})
    actual = config(assets: %{"petr4" => asset("petr4")})

    assert %{assets: %{added: [], removed: [], changed: [], unchanged: ["petr4"]}} =
             ConfigDiff.diff(desired, actual)
  end

  test "a Defaults-only edit surfaces as changed assets/rules once resolved (RFC-0006 §10)" do
    # Config.validate/1 resolves Defaults into asset.interval / rule.cooldown before
    # the diff ever runs, so a bare Defaults change is invisible to ConfigDiff
    # directly — it must already show up as a changed Asset/Rule by the time it
    # gets here. This test documents that the diff engine itself only sees the
    # resolved structs, matching how Reconciler always calls it post-validate.
    old_defaults = %Defaults{name: "global", interval: "1m", cooldown: "5m"}
    new_defaults = %Defaults{name: "global", interval: "2m", cooldown: "5m"}

    desired = config(assets: %{"petr4" => asset("petr4", "2m")}, defaults: new_defaults)
    actual = config(assets: %{"petr4" => asset("petr4", "1m")}, defaults: old_defaults)

    assert %{assets: %{changed: ["petr4"]}} = ConfigDiff.diff(desired, actual)
  end

  test "rules and notifiers are diffed independently of assets" do
    desired =
      config(
        assets: %{"petr4" => asset("petr4")},
        rules: %{"breakout" => rule("breakout", "petr4", "10m")},
        notifiers: %{"telegram" => telegram("telegram")}
      )

    actual =
      config(
        assets: %{"petr4" => asset("petr4")},
        rules: %{"breakout" => rule("breakout", "petr4", "5m")},
        notifiers: %{}
      )

    diff = ConfigDiff.diff(desired, actual)

    assert %{assets: %{unchanged: ["petr4"]}} = diff
    assert %{rules: %{changed: ["breakout"]}} = diff
    assert %{notifiers: %{added: ["telegram"]}} = diff
  end

  test "multiple names of the same kind are each classified and sorted" do
    desired =
      config(
        assets: %{
          "added_one" => asset("added_one"),
          "same" => asset("same"),
          "changed_one" => asset("changed_one", "2s")
        }
      )

    actual =
      config(
        assets: %{
          "same" => asset("same"),
          "changed_one" => asset("changed_one", "1s"),
          "removed_one" => asset("removed_one")
        }
      )

    assert %{
             assets: %{
               added: ["added_one"],
               removed: ["removed_one"],
               changed: ["changed_one"],
               unchanged: ["same"]
             }
           } = ConfigDiff.diff(desired, actual)
  end
end
