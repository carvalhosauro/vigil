defmodule Vigil.CLI.Commands.Validate do
  @moduledoc """
  `vigil validate` — validates the full configuration without starting the
  daemon (RFC-0010 §6). Runs the same parse/validate path as the daemon
  (DEC-002), so it is suitable for CI.
  """

  alias Vigil.Adapters.ConfigLoader
  alias Vigil.CLI.ErrorRenderer
  alias Vigil.Core.Config
  alias Vigil.Core.Config.Error

  @doc """
  Runs the `validate` command. `opts` is the parsed global option keyword
  list; `:config` selects the configuration directory (defaults to
  `ConfigLoader.config_dir/0`) and `:format` selects text or json output.
  """
  @spec run(keyword()) :: {iodata(), iodata(), 0 | 2}
  def run(opts) do
    dir = Keyword.get(opts, :config, ConfigLoader.config_dir())
    format = Keyword.get(opts, :format, "text")

    case ConfigLoader.load(dir) do
      {:ok, config} -> success(config, format)
      {:error, [%Error{} | _] = errors} -> config_errors(errors, format)
      {:error, reason} -> loader_error(reason, format)
    end
  end

  @spec success(Config.t(), String.t()) :: {iodata(), iodata(), 0}
  defp success(%Config{assets: assets, rules: rules, telegrams: telegrams}, format) do
    counts = %{assets: map_size(assets), rules: map_size(rules), notifiers: map_size(telegrams)}

    # `Main` validates --format; anything else falls back to text.
    case format do
      "json" ->
        body = Map.merge(%{ok: true}, counts)
        {Jason.encode!(body) <> "\n", "", 0}

      _text ->
        {"ok: #{counts.assets} assets, #{counts.rules} rules, #{counts.notifiers} notifiers\n",
         "", 0}
    end
  end

  @spec config_errors([Error.t()], String.t()) :: {iodata(), iodata(), 2}
  defp config_errors(errors, "json") do
    body = %{ok: false, errors: Enum.map(errors, &ErrorRenderer.to_map/1)}
    {"", Jason.encode!(body) <> "\n", 2}
  end

  defp config_errors(errors, _text) do
    stderr = Enum.map(errors, &["error: ", ErrorRenderer.render(&1), "\n"])
    {"", stderr, 2}
  end

  @spec loader_error(term(), String.t()) :: {iodata(), iodata(), 2}
  defp loader_error(reason, "json") do
    body = %{ok: false, errors: [%{message: ErrorRenderer.render_loader_error(reason)}]}
    {"", Jason.encode!(body) <> "\n", 2}
  end

  defp loader_error(reason, _text) do
    {"", "error: " <> ErrorRenderer.render_loader_error(reason) <> "\n", 2}
  end
end
