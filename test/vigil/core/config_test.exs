defmodule Vigil.Core.ConfigTest do
  use ExUnit.Case, async: true

  alias Vigil.Core.Config
  alias Vigil.Core.Config.{Asset, Defaults, Rule, Telegram}
  alias Vigil.Core.Context
  alias Vigil.Core.MarketSnapshot
  alias Vigil.Core.RuleEngine

  defp asset_resource(overrides \\ []) do
    Map.merge(
      %{
        "apiVersion" => "v1",
        "kind" => "Asset",
        "metadata" => %{"name" => "petr4"},
        "spec" => %{"symbol" => "PETR4.SA", "provider" => "yahoo"}
      },
      Map.new(overrides)
    )
  end

  defp defaults_resource(overrides \\ []) do
    Map.merge(
      %{
        "apiVersion" => "v1",
        "kind" => "Defaults",
        "metadata" => %{"name" => "global"},
        "spec" => %{"polling" => %{"interval" => "1m"}}
      },
      Map.new(overrides)
    )
  end

  defp telegram_resource(overrides \\ []) do
    Map.merge(
      %{
        "apiVersion" => "v1",
        "kind" => "Telegram",
        "metadata" => %{"name" => "telegram"},
        "spec" => %{"token" => "${TELEGRAM_TOKEN}", "chat_id" => "${CHAT_ID}"}
      },
      Map.new(overrides)
    )
  end

  defp rule_resource(overrides \\ []) do
    Map.merge(
      %{
        "apiVersion" => "v1",
        "kind" => "Rule",
        "metadata" => %{"name" => "breakout"},
        "spec" => %{
          "asset" => "petr4",
          "when" => %{
            "all" => [
              %{"field" => "price", "op" => "gt", "value" => 40}
            ]
          },
          "actions" => ["telegram"]
        }
      },
      Map.new(overrides)
    )
  end

  defp valid_bundle(overrides) do
    defaults = Keyword.get(overrides, :defaults, defaults_resource())
    telegram = Keyword.get(overrides, :telegram, telegram_resource())
    asset = Keyword.get(overrides, :asset, asset_resource())
    rule = Keyword.get(overrides, :rule, rule_resource())

    [defaults, telegram, asset, rule]
  end

  defp context(overrides) do
    defaults = [
      symbol: "PETR4.SA",
      timestamp: ~U[2026-07-01 10:30:00Z],
      open: 37.90,
      high: 38.60,
      low: 37.80,
      close: 38.42,
      price: 38.42,
      volume: 845_231
    ]

    MarketSnapshot
    |> struct!(Keyword.merge(defaults, overrides))
    |> Context.build(asset: "petr4", provider: "yahoo")
  end

  describe "validate/1" do
    test "accepts a valid bundle and resolves asset interval from defaults" do
      asset = asset_resource(%{"spec" => %{"symbol" => "PETR4.SA", "provider" => "yahoo"}})

      assert {:ok, config} = Config.validate(valid_bundle(asset: asset))

      assert %Asset{name: "petr4", symbol: "PETR4.SA", provider: "yahoo", interval: "1m"} =
               Map.fetch!(config.assets, "petr4")

      assert %Defaults{name: "global", interval: "1m"} = config.defaults
      assert %Telegram{name: "telegram"} = Map.fetch!(config.telegrams, "telegram")

      assert %Rule{name: "breakout", asset: "petr4", actions: ["telegram"]} =
               Map.fetch!(config.rules, "breakout")
    end

    test "keeps an explicit asset interval over defaults" do
      asset =
        asset_resource(%{
          "spec" => %{
            "symbol" => "PETR4.SA",
            "provider" => "yahoo",
            "interval" => "30s"
          }
        })

      assert {:ok, config} = Config.validate(valid_bundle(asset: asset))
      assert %Asset{interval: "30s"} = Map.fetch!(config.assets, "petr4")
    end

    test "rejects missing required asset fields" do
      asset = asset_resource(%{"spec" => %{"provider" => "yahoo"}})

      assert {:error,
              %Config.Error{kind: "Asset", name: "petr4", reason: {:missing_field, "spec.symbol"}}} =
               Config.validate(valid_bundle(asset: asset))
    end

    test "rejects invalid resource names" do
      asset = asset_resource(%{"metadata" => %{"name" => "PETR4"}})

      assert {:error,
              %Config.Error{kind: "Asset", name: "PETR4", reason: {:invalid_name, "PETR4"}}} =
               Config.validate(valid_bundle(asset: asset))
    end

    test "rejects duplicate names within the same kind" do
      duplicate = asset_resource(%{"metadata" => %{"name" => "petr4"}})

      assert {:error,
              %Config.Error{
                kind: "Asset",
                name: "petr4",
                reason: {:duplicate_name, "petr4"}
              }} = Config.validate([duplicate, duplicate])
    end

    test "rejects unsupported apiVersion" do
      asset = asset_resource(%{"apiVersion" => "v2"})

      assert {:error,
              %Config.Error{
                kind: "Asset",
                name: "petr4",
                reason: {:unsupported_api_version, "v2"}
              }} = Config.validate([asset])
    end

    test "rejects unknown kind" do
      resource = asset_resource(%{"kind" => "Portfolio"})

      assert {:error,
              %Config.Error{
                kind: "Portfolio",
                name: "petr4",
                reason: {:unsupported_kind, "Portfolio"}
              }} = Config.validate([resource])
    end

    test "rejects unknown provider" do
      asset =
        asset_resource(%{
          "spec" => %{"symbol" => "PETR4.SA", "provider" => "alpha", "interval" => "30s"}
        })

      assert {:error,
              %Config.Error{
                kind: "Asset",
                name: "petr4",
                reason: {:invalid_value, "spec.provider", :unknown_provider}
              }} = Config.validate(valid_bundle(asset: asset))
    end

    test "rejects invalid duration values" do
      asset =
        asset_resource(%{
          "spec" => %{"symbol" => "PETR4.SA", "provider" => "yahoo", "interval" => "30sec"}
        })

      assert {:error,
              %Config.Error{
                kind: "Asset",
                name: "petr4",
                reason: {:invalid_value, "spec.interval", :invalid_duration}
              }} = Config.validate(valid_bundle(asset: asset))
    end

    test "rejects missing asset reference from rules" do
      rule = rule_resource(%{"spec" => Map.put(rule_resource()["spec"], "asset", "missing")})

      assert {:error,
              %Config.Error{
                kind: "Rule",
                name: "breakout",
                reason: {:unknown_reference, "spec.asset", "missing"}
              }} = Config.validate(valid_bundle(rule: rule))
    end

    test "rejects missing notifier reference from rule actions" do
      rule =
        rule_resource(%{
          "spec" =>
            rule_resource()["spec"]
            |> Map.put("actions", ["discord"])
        })

      assert {:error,
              %Config.Error{
                kind: "Rule",
                name: "breakout",
                reason: {:invalid_value, "spec.actions", :unknown_notifier}
              }} = Config.validate(valid_bundle(rule: rule))
    end

    test "rejects rule actions that reference an unknown telegram resource" do
      rule = rule_resource()

      assert {:error,
              %Config.Error{
                kind: "Rule",
                name: "breakout",
                reason: {:unknown_reference, "spec.actions", "telegram"}
              }} =
               Config.validate([
                 defaults_resource(),
                 asset_resource(),
                 rule
               ])
    end

    test "rejects telegram secrets not provided via environment variables" do
      telegram =
        telegram_resource(%{
          "spec" => %{"token" => "plain-secret", "chat_id" => "${CHAT_ID}"}
        })

      assert {:error,
              %Config.Error{
                kind: "Telegram",
                name: "telegram",
                reason: {:invalid_value, "spec.token", :must_use_env_var}
              }} = Config.validate(valid_bundle(telegram: telegram))
    end

    test "rejects invalid rule condition structure" do
      rule =
        rule_resource(%{
          "spec" =>
            Map.put(rule_resource()["spec"], "when", %{
              "field" => "pricee",
              "op" => "gt",
              "value" => 40
            })
        })

      assert {:error,
              %Config.Error{
                kind: "Rule",
                name: "breakout",
                reason: {:invalid_value, "spec.when", {:unknown_field, "pricee"}}
              }} = Config.validate(valid_bundle(rule: rule))
    end

    test "rejects asset without interval when defaults is missing" do
      asset = asset_resource(%{"spec" => %{"symbol" => "PETR4.SA", "provider" => "yahoo"}})

      assert {:error,
              %Config.Error{
                kind: "Asset",
                name: "petr4",
                reason: {:missing_interval, :no_defaults}
              }} =
               Config.validate([
                 telegram_resource(),
                 asset,
                 rule_resource()
               ])
    end

    test "accepts atom keys in resource maps" do
      asset = %{
        apiVersion: "v1",
        kind: "Asset",
        metadata: %{name: "petr4"},
        spec: %{symbol: "PETR4.SA", provider: "yahoo", interval: "30s"}
      }

      assert {:ok, config} =
               Config.validate([
                 defaults_resource(),
                 telegram_resource(),
                 asset,
                 rule_resource()
               ])

      assert %Asset{interval: "30s"} = Map.fetch!(config.assets, "petr4")
    end

    test "rejects missing apiVersion" do
      asset = asset_resource() |> Map.delete("apiVersion")

      assert {:error, %Config.Error{reason: {:missing_field, "apiVersion"}}} =
               Config.validate([asset])
    end

    test "rejects missing metadata name" do
      asset = asset_resource(%{"metadata" => %{}})

      assert {:error, %Config.Error{reason: {:missing_field, "metadata.name"}}} =
               Config.validate([asset])
    end

    test "keeps only the first defaults resource" do
      first = defaults_resource(%{"spec" => %{"polling" => %{"interval" => "1m"}}})

      second =
        defaults_resource(%{
          "metadata" => %{"name" => "backup"},
          "spec" => %{"polling" => %{"interval" => "30s"}}
        })

      assert {:ok, config} =
               Config.validate([
                 first,
                 second,
                 telegram_resource(),
                 asset_resource(),
                 rule_resource()
               ])

      assert %Defaults{interval: "1m"} = config.defaults
    end

    test "rejects unknown spec fields" do
      asset =
        asset_resource(%{
          "spec" => %{"symbol" => "PETR4.SA", "provider" => "yahoo", "extra" => true}
        })

      assert {:error, %Config.Error{reason: {:invalid_field, "spec.extra"}}} =
               Config.validate(valid_bundle(asset: asset))
    end

    test "rejects empty actions" do
      rule =
        rule_resource(%{
          "spec" => rule_resource()["spec"] |> Map.put("actions", [])
        })

      assert {:error, %Config.Error{reason: {:invalid_value, "spec.actions", :empty_actions}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "rejects non-string action entries" do
      rule =
        rule_resource(%{
          "spec" => rule_resource()["spec"] |> Map.put("actions", [:telegram])
        })

      assert {:error, %Config.Error{reason: {:invalid_type, "spec.actions", "string"}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "rejects unsupported operators in conditions" do
      rule =
        rule_resource(%{
          "spec" =>
            Map.put(rule_resource()["spec"], "when", %{
              "field" => "price",
              "op" => "neq",
              "value" => 40
            })
        })

      assert {:error, %Config.Error{reason: {:invalid_value, "spec.when", :unsupported_operator}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "accepts logical any and not conditions" do
      rule =
        rule_resource(%{
          "spec" =>
            Map.put(rule_resource()["spec"], "when", %{
              "not" => %{
                "any" => [
                  %{"field" => "price", "op" => "lt", "value" => 30},
                  %{"field" => "volume", "op" => "eq", "value" => 0}
                ]
              }
            })
        })

      assert {:ok, config} = Config.validate(valid_bundle(rule: rule))

      assert %Rule{condition: %{not: %{any: [_ | _]}}} =
               Map.fetch!(config.rules, "breakout")
    end

    test "rejects invalid condition shapes" do
      rule =
        rule_resource(%{
          "spec" => Map.put(rule_resource()["spec"], "when", %{"broken" => true})
        })

      assert {:error,
              %Config.Error{reason: {:invalid_value, "spec.when", :invalid_condition_shape}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "rejects non-map when blocks" do
      rule =
        rule_resource(%{
          "spec" => Map.put(rule_resource()["spec"], "when", "price > 40")
        })

      assert {:error, %Config.Error{reason: {:invalid_type, "spec.when", "map"}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "rejects empty logical condition lists" do
      rule =
        rule_resource(%{
          "spec" => Map.put(rule_resource()["spec"], "when", %{"all" => []})
        })

      assert {:error,
              %Config.Error{reason: {:invalid_value, "spec.when.all", :empty_condition_list}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "rejects non-map entries inside logical conditions" do
      rule =
        rule_resource(%{
          "spec" => Map.put(rule_resource()["spec"], "when", %{"all" => ["price > 40"]})
        })

      assert {:error, %Config.Error{reason: {:invalid_type, "spec.when.all", "map"}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "rejects invalid metadata and spec types" do
      asset = asset_resource(%{"metadata" => "petr4"})

      assert {:error, %Config.Error{reason: {:invalid_type, "metadata", "map"}}} =
               Config.validate([asset])

      asset = asset_resource(%{"spec" => "invalid"})

      assert {:error, %Config.Error{reason: {:invalid_type, "spec", "map"}}} =
               Config.validate([asset])
    end

    test "rejects invalid defaults polling types" do
      defaults = defaults_resource(%{"spec" => %{"polling" => "1m"}})

      assert {:error, %Config.Error{reason: {:invalid_type, "spec.polling", "map"}}} =
               Config.validate([defaults])

      defaults = defaults_resource(%{"spec" => %{"polling" => %{"interval" => 60}}})

      assert {:error, %Config.Error{reason: {:invalid_type, "spec.polling.interval", "string"}}} =
               Config.validate([defaults])
    end

    test "rejects invalid list and string fields on rules" do
      rule = rule_resource(%{"spec" => Map.delete(rule_resource()["spec"], "actions")})

      assert {:error, %Config.Error{reason: {:missing_field, "spec.actions"}}} =
               Config.validate(valid_bundle(rule: rule))

      rule =
        rule_resource(%{
          "spec" => rule_resource()["spec"] |> Map.put("actions", "telegram")
        })

      assert {:error, %Config.Error{reason: {:invalid_type, "spec.actions", "list"}}} =
               Config.validate(valid_bundle(rule: rule))

      rule =
        rule_resource(%{
          "spec" => rule_resource()["spec"] |> Map.put("asset", 123)
        })

      assert {:error, %Config.Error{reason: {:invalid_type, "spec.asset", "string"}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "propagates nested condition validation errors through all" do
      rule =
        rule_resource(%{
          "spec" =>
            Map.put(rule_resource()["spec"], "when", %{
              "all" => [
                %{"field" => "price", "op" => "gt", "value" => 40},
                %{"field" => "price", "op" => "nope", "value" => 40}
              ]
            })
        })

      assert {:error,
              %Config.Error{reason: {:invalid_value, "spec.when.all", :unsupported_operator}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "rejects non-map not conditions" do
      rule =
        rule_resource(%{
          "spec" => Map.put(rule_resource()["spec"], "when", %{"not" => "price > 40"})
        })

      assert {:error, %Config.Error{reason: {:invalid_type, "spec.when.not", "map"}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "rejects missing structural fields" do
      asset = asset_resource() |> Map.delete("metadata")

      assert {:error, %Config.Error{reason: {:missing_field, "metadata"}}} =
               Config.validate([asset])

      rule =
        rule_resource(%{
          "spec" => rule_resource()["spec"] |> Map.delete("when")
        })

      assert {:error, %Config.Error{reason: {:missing_field, "spec.when"}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "rejects non-string duration values on assets" do
      asset =
        asset_resource(%{
          "spec" => %{"symbol" => "PETR4.SA", "provider" => "yahoo", "interval" => 30}
        })

      assert {:error, %Config.Error{reason: {:invalid_type, "spec.interval", "duration"}}} =
               Config.validate(valid_bundle(asset: asset))
    end

    test "requires a value in leaf conditions" do
      rule =
        rule_resource(%{
          "spec" => Map.put(rule_resource()["spec"], "when", %{"field" => "price", "op" => "gt"})
        })

      assert {:error, %Config.Error{reason: {:missing_field, "spec.when.value"}}} =
               Config.validate(valid_bundle(rule: rule))
    end

    test "produces an atom-keyed condition the rule engine can evaluate directly" do
      assert {:ok, config} = Config.validate(valid_bundle([]))
      rule = Map.fetch!(config.rules, "breakout")

      assert rule.condition == %{all: [%{field: :price, op: :gt, value: 40}]}
      assert {:ok, true} = RuleEngine.evaluate(rule.condition, context(price: 41.0))
      assert {:ok, false} = RuleEngine.evaluate(rule.condition, context(price: 39.0))
    end

    test "normalizes conditions that already use atom keys" do
      rule =
        rule_resource(%{
          "spec" =>
            Map.put(rule_resource()["spec"], "when", %{
              all: [%{field: "price", op: "gt", value: 40}]
            })
        })

      assert {:ok, config} = Config.validate(valid_bundle(rule: rule))

      assert %Rule{condition: %{all: [%{field: :price, op: :gt, value: 40}]}} =
               Map.fetch!(config.rules, "breakout")
    end
  end

  describe "cooldown" do
    test "rule cooldown is parsed from spec" do
      rule =
        rule_resource(%{
          "spec" => rule_resource()["spec"] |> Map.put("cooldown", "10m")
        })

      resources = [defaults_resource(), asset_resource(), telegram_resource(), rule]

      assert {:ok, config} = Config.validate(resources)
      assert config.rules["breakout"].cooldown == "10m"
    end

    test "rule without cooldown inherits Defaults notifications.cooldown" do
      defaults =
        defaults_resource(%{
          "spec" => %{
            "polling" => %{"interval" => "1m"},
            "notifications" => %{"cooldown" => "2m"}
          }
        })

      resources = [defaults, asset_resource(), telegram_resource(), rule_resource()]

      assert {:ok, config} = Config.validate(resources)
      assert config.rules["breakout"].cooldown == "2m"
    end

    test "falls back to the 5m system default when Defaults omits notifications" do
      resources = [defaults_resource(), asset_resource(), telegram_resource(), rule_resource()]

      assert {:ok, config} = Config.validate(resources)
      assert config.rules["breakout"].cooldown == "5m"
    end

    test "rejects an invalid cooldown duration" do
      rule =
        rule_resource(%{
          "spec" => rule_resource()["spec"] |> Map.put("cooldown", "fast")
        })

      resources = [defaults_resource(), asset_resource(), telegram_resource(), rule]

      assert {:error,
              %Config.Error{
                kind: "Rule",
                reason: {:invalid_value, "spec.cooldown", :invalid_duration}
              }} =
               Config.validate(resources)
    end

    test "rejects an invalid Defaults notifications.cooldown" do
      defaults =
        defaults_resource(%{
          "spec" => %{
            "polling" => %{"interval" => "1m"},
            "notifications" => %{"cooldown" => 5}
          }
        })

      assert {:error, %Config.Error{kind: "Defaults"}} = Config.validate([defaults])
    end
  end
end
