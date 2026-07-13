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

  Four outcomes are distinguished:

    * the *connect* stage failing (no daemon running) — exit 3;
    * a rejected reload (`{"ok": false, ...}` — the on-disk config is
      invalid; the daemon guarantees the running configuration is left
      untouched) — exit 2, matching `validate`'s exit code for invalid
      configuration;
    * a successful reload (config valid) where applying it failed for one
      or more assets (`"failed"` non-empty in the payload) — exit 1. This is
      deliberately distinct from both 0 (clean success) and 2 (the config
      itself was rejected): the config passed validation and most of the
      diff applied, but at least one asset did not converge, which is
      scriptable-worth-noticing without implying the reload was rejected;
    * a malformed, truncated, non-JSON, or key-incomplete reply — a
      different failure again, since the daemon answered, it just answered
      unusably — also exit 1 (the same code as a partial apply, since both
      are "something is not fully right" as opposed to unreachable/rejected).
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
    # `failed` is read defensively rather than pattern-matched so a success
    # reply from a daemon predating the partial-apply field still renders
    # cleanly instead of falling through to "malformed".
    failed = Map.get(payload, "failed", [])

    stdout =
      case format do
        "json" ->
          Jason.encode!(payload) <> "\n"

        _text ->
          "reload: #{length(added)} added, #{length(changed)} changed, #{length(removed)} removed\n"
      end

    case failed do
      [] ->
        {stdout, "", 0}

      names ->
        {stdout, "warning: #{failed_phrase(names)}: #{Enum.join(names, ", ")}\n", 1}
    end
  end

  defp render(%{"ok" => false, "error" => error} = payload, format, _path) do
    case format do
      "json" -> {"", Jason.encode!(payload) <> "\n", 2}
      _text -> {"", "error: reload rejected: #{error}\n", 2}
    end
  end

  defp render(_payload, _format, path), do: malformed_response(path)

  @spec failed_phrase([String.t()]) :: String.t()
  defp failed_phrase([_one]), do: "1 asset failed to apply"
  defp failed_phrase(names), do: "#{length(names)} assets failed to apply"

  @spec not_reachable(String.t()) :: {iodata(), iodata(), 3}
  defp not_reachable(path), do: {"", "error: daemon not reachable at #{path}\n", 3}

  @spec malformed_response(String.t()) :: {iodata(), iodata(), 1}
  defp malformed_response(_path), do: {"", "error: malformed response from daemon\n", 1}
end
