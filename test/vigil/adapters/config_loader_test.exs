defmodule Vigil.Adapters.ConfigLoaderTest do
  use ExUnit.Case, async: false

  alias Vigil.Adapters.ConfigLoader

  @valid_dir "test/fixtures/configs_valid"

  describe "config_dir/0" do
    test "defaults to configs" do
      # Self-contained: other suites (CLI validate/start) set VIGIL_CONFIG_DIR
      # or the :config_dir app env, both process-global. Clear them so this
      # default read never sees a leaked override.
      System.delete_env("VIGIL_CONFIG_DIR")
      Application.delete_env(:vigil, :config_dir)

      assert ConfigLoader.config_dir() == "configs"
    end

    test "app env overrides the default" do
      Application.put_env(:vigil, :config_dir, "/tmp/x")
      on_exit(fn -> Application.delete_env(:vigil, :config_dir) end)

      assert ConfigLoader.config_dir() == "/tmp/x"
    end

    test "VIGIL_CONFIG_DIR wins over app env" do
      Application.put_env(:vigil, :config_dir, "/tmp/x")
      System.put_env("VIGIL_CONFIG_DIR", "/tmp/y")

      on_exit(fn ->
        Application.delete_env(:vigil, :config_dir)
        System.delete_env("VIGIL_CONFIG_DIR")
      end)

      assert ConfigLoader.config_dir() == "/tmp/y"
    end
  end

  describe "read_resources/1" do
    test "reads every yaml file recursively, sorted by path" do
      assert {:ok, resources} = ConfigLoader.read_resources(@valid_dir)
      assert length(resources) == 4
      assert Enum.all?(resources, &is_map/1)
      kinds = resources |> Enum.map(& &1["kind"]) |> Enum.sort()
      assert kinds == ["Asset", "Defaults", "Rule", "Telegram"]
    end

    test "missing directory" do
      assert {:error, {:config_dir_not_found, "test/fixtures/nope"}} =
               ConfigLoader.read_resources("test/fixtures/nope")
    end

    test "empty directory" do
      dir = Path.join(System.tmp_dir!(), "vigil_empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:error, {:no_resources, ^dir}} = ConfigLoader.read_resources(dir)
    end

    test "invalid yaml reports the file" do
      assert {:error, {:yaml_error, "test/fixtures/configs_bad_yaml/broken.yaml", _}} =
               ConfigLoader.read_resources("test/fixtures/configs_bad_yaml")
    end

    test "single non-map YAML document (scalar) reports not_a_map" do
      assert {:error, {:yaml_error, "test/fixtures/configs_scalar_doc/scalar.yaml", :not_a_map}} =
               ConfigLoader.read_resources("test/fixtures/configs_scalar_doc")
    end

    test "multi-document YAML file reports multiple_documents" do
      assert {:error, {:multiple_documents, "test/fixtures/configs_multi_doc/multi.yaml"}} =
               ConfigLoader.read_resources("test/fixtures/configs_multi_doc")
    end
  end

  describe "load/1" do
    setup do
      System.put_env("TELEGRAM_TOKEN", "tok")
      System.put_env("CHAT_ID", "123")

      on_exit(fn ->
        System.delete_env("TELEGRAM_TOKEN")
        System.delete_env("CHAT_ID")
      end)
    end

    test "loads and validates the full fixture directory" do
      assert {:ok, %Vigil.Core.Config{} = config} = ConfigLoader.load(@valid_dir)
      assert Map.has_key?(config.assets, "petr4")
      assert config.rules["breakout"].cooldown == "10m"
      assert config.defaults.cooldown == "5m"
    end

    test "fails when a referenced env var is missing (RFC-0003 DEC-008)" do
      System.delete_env("CHAT_ID")

      assert {:error, {:missing_env_vars, ["CHAT_ID"]}} = ConfigLoader.load(@valid_dir)
    end

    test "reports ALL missing env vars at once instead of stopping at the first" do
      System.delete_env("TELEGRAM_TOKEN")
      System.delete_env("CHAT_ID")

      assert {:error, {:missing_env_vars, vars}} = ConfigLoader.load(@valid_dir)
      assert Enum.sort(vars) == ["CHAT_ID", "TELEGRAM_TOKEN"]
    end

    test "propagates validation errors from Config" do
      dir = Path.join(System.tmp_dir!(), "vigil_invalid_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "asset.yaml"), """
      apiVersion: v1
      kind: Asset
      metadata:
        name: petr4
      spec:
        provider: yahoo
      """)

      assert {:error, [%Vigil.Core.Config.Error{kind: "Asset"}]} = ConfigLoader.load(dir)
    end
  end
end
