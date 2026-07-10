defmodule Vigil.Adapters.ConfigLoaderTest do
  use ExUnit.Case, async: false

  alias Vigil.Adapters.ConfigLoader

  @valid_dir "test/fixtures/configs_valid"

  describe "config_dir/0" do
    test "defaults to configs" do
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
  end
end
