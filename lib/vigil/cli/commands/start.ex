defmodule Vigil.CLI.Commands.Start do
  @moduledoc """
  `vigil start` — starts the daemon (RFC-0010 §7).

  Startup sequence: parse & validate configuration, refuse to start if
  invalid (exit 2, DEC-003), otherwise initialize the Runtime (which starts
  schedules and the control channel) and block in the foreground.

  ## Deviation from the `run/1` contract

  `Vigil.CLI.Main` documents that `run/1` never touches stdio and never
  blocks, so tests can exercise it safely. `start` cannot honor that on the
  success path: a successful start blocks forever (the daemon runs in the
  foreground) and never "returns" for `Main.print/2` to render. The startup
  banner is therefore written directly to stdout with `IO.write/1` *before*
  blocking.

  To keep `run/2` testable, the blocking step itself is injected as
  `block_fun` (default: sleep forever). Tests pass a no-op `block_fun`, so
  `run/2` returns immediately after starting the application and printing the
  banner — `ExUnit.CaptureIO` captures that banner for assertions. The error
  path (invalid configuration) is unaffected: it still returns the normal
  `{stdout, stderr, exit_code}` tuple and never calls `block_fun`.
  """

  alias Vigil.Adapters.ConfigLoader
  alias Vigil.Adapters.ControlSocket
  alias Vigil.CLI.ErrorRenderer
  alias Vigil.Core.Config.Error

  @doc """
  Runs the `start` command. `opts` is the parsed global option keyword list;
  `:config` sets the configuration directory for this run, `:format` selects
  text or json error rendering. `block_fun` is called with no arguments after
  a successful start and defaults to blocking forever; tests inject a no-op
  to get control back.
  """
  @spec run(keyword(), (-> any())) :: {iodata(), iodata(), 0 | 2}
  def run(opts, block_fun \\ &block_forever/0) do
    if dir = Keyword.get(opts, :config) do
      Application.put_env(:vigil, :config_dir, dir)
    end

    Application.put_env(:vigil, :start_runtime, true)
    # `Main.boot/0` already started :vigil with the Runtime disabled; restart
    # it so the updated env (config_dir, start_runtime) takes effect.
    _ = Application.stop(:vigil)

    case Application.ensure_all_started(:vigil) do
      {:ok, _apps} -> start_success(block_fun)
      {:error, reason} -> start_failure(reason, Keyword.get(opts, :format, "text"))
    end
  end

  @spec start_success((-> any())) :: {iodata(), iodata(), 0}
  defp start_success(block_fun) do
    config_dir = ConfigLoader.config_dir()
    socket_path = ControlSocket.path()
    IO.write("vigil daemon started (config: #{config_dir}, socket: #{socket_path})\n")
    block_fun.()
    {"", "", 0}
  end

  @spec start_failure(term(), String.t()) :: {iodata(), iodata(), 2}
  defp start_failure(reason, format) do
    case extract_config_error(reason) do
      {:ok, [%Error{} | _] = errors} -> config_errors(errors, format)
      {:ok, other} -> loader_error(other, format)
      :error -> loader_error(reason, format)
    end
  end

  # Shape of Application.ensure_all_started/1's error when
  # Vigil.Runtime.Supervisor.start_link/1 refuses an invalid config
  # (RFC-0010 DEC-003) — verified against the running application, not
  # documented by the stdlib.
  @spec extract_config_error(term()) :: {:ok, term()} | :error
  defp extract_config_error(
         {:vigil,
          {{:shutdown,
            {:failed_to_start_child, Vigil.Runtime.Supervisor, {:invalid_config, config_reason}}},
           _mfa}}
       ) do
    {:ok, config_reason}
  end

  defp extract_config_error(_other), do: :error

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

  defp block_forever, do: :timer.sleep(:infinity)
end
