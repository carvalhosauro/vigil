defmodule Vigil.CLI.Commands.Reload do
  @moduledoc """
  `vigil reload` — the CLI client of the daemon's control channel (RFC-0010
  §9, §11, §13). Connects to the Unix domain socket exposed by
  `Vigil.Runtime.Control`, sends `"reload\\n"`, and renders the single JSON
  reply line the daemon sends back before closing the connection.

  Mirrors `Vigil.CLI.Commands.Status` (RFC-0010 DEC-001): this command never
  touches `Vigil.Runtime` directly — the socket is the only contract between
  the CLI and the daemon, and the daemon runs the exact same reconciliation
  path a filesystem-triggered reload would (RFC-0006 §15).

  ## Exit codes (RFC-0010 §11)

  Three failure stages are distinguished:

    * the *connect* stage failing (no daemon running) — exit 3;
    * a rejected reload (`{"ok": false, ...}` — the on-disk config is
      invalid; the daemon guarantees the running configuration is left
      untouched) — exit 2, matching `validate`'s exit code for invalid
      configuration;
    * a malformed, truncated, non-JSON, or key-incomplete reply — a
      different failure from a rejected reload, since the daemon answered,
      it just answered unusably — exit 1.
  """

  alias Vigil.Adapters.ControlSocket

  @connect_opts [:binary, active: false, packet: :line, packet_size: 65_536]
  @timeout 5_000

  @doc """
  Runs the `reload` command. `opts` is the parsed global option keyword
  list; `:socket` overrides the control channel path (defaults to
  `ControlSocket.path/0`), `:format` selects text or json output.
  """
  @spec run(keyword()) :: {iodata(), iodata(), 0 | 1 | 2 | 3}
  def run(opts) do
    path = opts[:socket] || ControlSocket.path()
    format = Keyword.get(opts, :format, "text")

    case :gen_tcp.connect({:local, path}, 0, @connect_opts, @timeout) do
      {:ok, socket} -> fetch_reload(socket, path, format)
      {:error, _reason} -> not_reachable(path)
    end
  end

  @spec fetch_reload(port(), String.t(), String.t()) :: {iodata(), iodata(), 0 | 1 | 2}
  defp fetch_reload(socket, path, format) do
    with :ok <- :gen_tcp.send(socket, "reload\n"),
         {:ok, line} <- :gen_tcp.recv(socket, 0, @timeout),
         {:ok, payload} <- Jason.decode(line) do
      render(payload, format, path)
    else
      _ -> malformed_response(path)
    end
  after
    :gen_tcp.close(socket)
  end

  @spec render(term(), String.t(), String.t()) :: {iodata(), iodata(), 0 | 1 | 2}
  defp render(
         %{"ok" => true, "added" => added, "changed" => changed, "removed" => removed} = payload,
         format,
         _path
       ) do
    case format do
      "json" ->
        {Jason.encode!(payload) <> "\n", "", 0}

      _text ->
        {"reload: #{length(added)} added, #{length(changed)} changed, #{length(removed)} removed\n",
         "", 0}
    end
  end

  defp render(%{"ok" => false, "error" => error} = payload, format, _path) do
    case format do
      "json" -> {"", Jason.encode!(payload) <> "\n", 2}
      _text -> {"", "error: reload rejected: #{error}\n", 2}
    end
  end

  defp render(_payload, _format, path), do: malformed_response(path)

  @spec not_reachable(String.t()) :: {iodata(), iodata(), 3}
  defp not_reachable(path), do: {"", "error: daemon not reachable at #{path}\n", 3}

  @spec malformed_response(String.t()) :: {iodata(), iodata(), 1}
  defp malformed_response(_path), do: {"", "error: malformed response from daemon\n", 1}
end
