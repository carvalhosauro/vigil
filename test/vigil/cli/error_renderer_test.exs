defmodule Vigil.CLI.ErrorRendererTest do
  use ExUnit.Case, async: true

  alias Vigil.CLI.ErrorRenderer
  alias Vigil.Core.Config.Error

  defp render(reason),
    do: ErrorRenderer.render(%Error{kind: "Asset", name: "petr4", reason: reason})

  describe "render/1 — reason tuples" do
    test "missing_field" do
      assert render({:missing_field, "spec.symbol"}) ==
               ~s(Asset/petr4: missing required field "spec.symbol")
    end

    test "invalid_field" do
      assert render({:invalid_field, "spec.pricee"}) ==
               ~s(Asset/petr4: unknown field "spec.pricee")
    end

    test "invalid_type" do
      assert render({:invalid_type, "spec.symbol", "string"}) ==
               ~s(Asset/petr4: field "spec.symbol" must be a string)
    end

    test "invalid_value with a plain value falls back to inspect" do
      assert render({:invalid_value, "spec.foo", 42}) ==
               ~s(Asset/petr4: field "spec.foo" has invalid value 42)
    end

    test "invalid_value :unknown_field" do
      assert render({:invalid_value, "spec.when", {:unknown_field, "pricee"}}) ==
               ~s(Asset/petr4: field "spec.when" references unknown field "pricee")
    end

    test "invalid_value :unknown_provider" do
      assert render({:invalid_value, "spec.provider", :unknown_provider}) ==
               ~s(Asset/petr4: field "spec.provider" has an unsupported provider)
    end

    test "invalid_value :unknown_notifier" do
      assert render({:invalid_value, "spec.actions", :unknown_notifier}) ==
               ~s(Asset/petr4: field "spec.actions" references an unsupported notifier)
    end

    test "invalid_value :empty_actions" do
      assert render({:invalid_value, "spec.actions", :empty_actions}) ==
               ~s(Asset/petr4: field "spec.actions" must not be empty)
    end

    test "invalid_value :empty_condition_list" do
      assert render({:invalid_value, "spec.when.all", :empty_condition_list}) ==
               ~s(Asset/petr4: field "spec.when.all" must not be empty)
    end

    test "invalid_value :invalid_condition_shape" do
      assert render({:invalid_value, "spec.when", :invalid_condition_shape}) ==
               "Asset/petr4: field \"spec.when\" has an invalid condition shape (expected all/any/not/field)"
    end

    test "invalid_value :unsupported_operator" do
      assert render({:invalid_value, "spec.when", :unsupported_operator}) ==
               ~s(Asset/petr4: field "spec.when" uses an unsupported operator)
    end

    test "invalid_value :invalid_duration" do
      assert render({:invalid_value, "spec.interval", :invalid_duration}) ==
               ~s(Asset/petr4: field "spec.interval" is not a valid duration)
    end

    test "invalid_value :must_use_env_var" do
      assert render({:invalid_value, "spec.token", :must_use_env_var}) ==
               ~s(Asset/petr4: field "spec.token" must reference an environment variable, e.g. ${VAR})
    end

    test "invalid_name" do
      assert render({:invalid_name, "PETR4"}) ==
               "Asset/petr4: invalid name \"PETR4\" (must match ^[a-z0-9]+(-[a-z0-9]+)*$)"
    end

    test "duplicate_name" do
      assert render({:duplicate_name, "petr4"}) == ~s(Asset/petr4: duplicate name "petr4")
    end

    test "unknown_reference" do
      assert render({:unknown_reference, "spec.asset", "vale3"}) ==
               ~s(Asset/petr4: field "spec.asset" references unknown "vale3")
    end

    test "unsupported_api_version" do
      assert render({:unsupported_api_version, "v2"}) ==
               ~s(Asset/petr4: unsupported apiVersion "v2")
    end

    test "unsupported_kind" do
      assert render({:unsupported_kind, "Widget"}) == ~s(Asset/petr4: unsupported kind "Widget")
    end

    test "missing_interval :no_defaults" do
      assert render({:missing_interval, :no_defaults}) ==
               "Asset/petr4: no interval configured and no Defaults resource is present"
    end

    test "missing_interval :no_system_default" do
      assert render({:missing_interval, :no_system_default}) ==
               "Asset/petr4: no interval configured and Defaults has no system default"
    end

    test "unknown reason falls back to inspect" do
      assert render({:something_new, "x"}) == ~s(Asset/petr4: {:something_new, "x"})
    end
  end

  describe "to_map/1" do
    test "renders kind/name/message" do
      error = %Error{kind: "Rule", name: "breakout", reason: {:missing_field, "spec.asset"}}

      assert ErrorRenderer.to_map(error) == %{
               kind: "Rule",
               name: "breakout",
               message: ~s(missing required field "spec.asset")
             }
    end
  end

  describe "render_loader_error/1" do
    test "config_dir_not_found" do
      assert ErrorRenderer.render_loader_error({:config_dir_not_found, "/nope"}) ==
               "configuration directory not found: /nope"
    end

    test "no_resources" do
      assert ErrorRenderer.render_loader_error({:no_resources, "/empty"}) ==
               "no configuration resources found in /empty"
    end

    test "yaml_error — not a map" do
      assert ErrorRenderer.render_loader_error({:yaml_error, "a.yaml", :not_a_map}) ==
               "a.yaml: YAML document is not a map"
    end

    test "yaml_error — parse error falls back to inspect" do
      assert ErrorRenderer.render_loader_error({:yaml_error, "a.yaml", :some_parse_failure}) ==
               "a.yaml: YAML parse error: :some_parse_failure"
    end

    test "multiple_documents" do
      assert ErrorRenderer.render_loader_error({:multiple_documents, "a.yaml"}) ==
               "a.yaml: contains multiple YAML documents (one resource per file)"
    end

    test "missing_env_vars" do
      assert ErrorRenderer.render_loader_error({:missing_env_vars, ["A", "B"]}) ==
               "missing required environment variable(s): A, B"
    end

    test "unknown reason falls back to inspect" do
      assert ErrorRenderer.render_loader_error(:weird) == ":weird"
    end
  end
end
