defmodule Vigil.Adapters.ConfigLoader do
  alias Vigil.Core.Config

  @moduledoc """
  Loads CRD resources from the configuration directory (RFC-0003 §4).

  Resolution of the directory: `VIGIL_CONFIG_DIR` env var, then
  `config :vigil, :config_dir`, then the conventional `"configs"` (RFC-0010 §5;
  the future CLI `--config` flag writes the same app-env key).

  One resource per file (RFC-0003 §6). Environment variables referenced as
  `${VAR}` are checked for presence (missing is a validation error, RFC-0003
  DEC-008) but NOT expanded here: secrets stay in `${VAR}` form inside the
  parsed config (`Config` enforces that shape for Telegram credentials) and are
  resolved by the consuming notifier at delivery time (RFC-0003 DEC-006).
  """

  @env_var_re ~r/\$\{([A-Z][A-Z0-9_]*)\}/

  @spec config_dir() :: String.t()
  def config_dir do
    System.get_env("VIGIL_CONFIG_DIR") ||
      Application.get_env(:vigil, :config_dir, "configs")
  end

  @spec load() :: {:ok, Config.t()} | {:error, term()}
  def load, do: load(config_dir())

  @spec load(String.t()) :: {:ok, Config.t()} | {:error, term()}
  def load(dir) do
    with {:ok, resources} <- read_resources(dir),
         :ok <- check_env_vars(resources),
         {:ok, config} <- Config.validate(resources) do
      {:ok, config}
    end
  end

  @spec read_resources(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_resources(dir) do
    cond do
      not File.dir?(dir) -> {:error, {:config_dir_not_found, dir}}
      true -> dir |> yaml_files() |> parse_files()
    end
  end

  # Presence check only — values are NOT expanded (see moduledoc).
  @spec check_env_vars([map()]) :: :ok | {:error, {:missing_env_var, String.t()}}
  defp check_env_vars(resources) do
    resources
    |> Enum.flat_map(&referenced_vars/1)
    |> Enum.uniq()
    |> Enum.find(&(System.get_env(&1) == nil))
    |> case do
      nil -> :ok
      var -> {:error, {:missing_env_var, var}}
    end
  end

  defp referenced_vars(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&referenced_vars/1)

  defp referenced_vars(value) when is_list(value),
    do: Enum.flat_map(value, &referenced_vars/1)

  defp referenced_vars(value) when is_binary(value) do
    @env_var_re
    |> Regex.scan(value, capture: :all_but_first)
    |> List.flatten()
  end

  defp referenced_vars(_value), do: []

  defp yaml_files(dir) do
    {dir, Path.wildcard(Path.join(dir, "**/*.{yml,yaml}")) |> Enum.sort()}
  end

  defp parse_files({dir, []}), do: {:error, {:no_resources, dir}}

  defp parse_files({_dir, paths}) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case parse_file(path) do
        {:ok, resource} -> {:cont, {:ok, [resource | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resources} -> {:ok, Enum.reverse(resources)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_file(path) do
    case YamlElixir.read_all_from_file(path) do
      {:ok, [doc]} when is_map(doc) -> {:ok, doc}
      {:ok, [_ | _]} -> {:error, {:multiple_documents, path}}
      {:ok, _} -> {:error, {:yaml_error, path, :not_a_map}}
      {:error, reason} -> {:error, {:yaml_error, path, reason}}
    end
  end
end
