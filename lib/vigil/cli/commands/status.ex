defmodule Vigil.CLI.Commands.Status do
  @moduledoc """
  `vigil status` — the CLI client of the daemon's control channel (RFC-0010
  §8, §11, §13). Connects to the Unix domain socket exposed by
  `Vigil.Runtime.Control`, sends `"status\\n"`, and renders the single JSON
  reply line the daemon sends back before closing the connection.

  This command never touches `Vigil.Runtime` directly (RFC-0010 DEC-001):
  the CLI and the daemon are separate OS processes, and the socket is the
  only contract between them.

  ## Exit codes (RFC-0010 §11)

  Two failure stages are distinguished:

    * the *connect* stage failing — no socket file, a stale file with
      nobody listening, or a connect timeout — is "daemon not reachable":
      exit 3;
    * the daemon accepting the connection but then producing an empty,
      truncated, or non-JSON reply is a different failure: the daemon is
      there, it just answered unusably. Exit 1, not 3.

  ## `last_update` rendering

  RFC-0010 §8's example shows a relative time ("3s ago"). This renders the
  raw ISO-8601 timestamp instead: a relative rendering needs a "now"
  reference, which would make output non-deterministic and awkward to test;
  ISO-8601 stays exactly reproducible while remaining human-scannable. A
  `null` `last_update` (an asset that has never completed a successful
  cycle) renders as `"never"`.
  """

  alias Vigil.Adapters.ControlSocket

  @columns ["asset", "provider", "interval", "last_update", "state"]
  # `packet_size` bounds the reply buffer (defense in depth — the daemon is
  # trusted, but a reply with no newline shouldn't buffer without limit); it
  # comfortably exceeds any real status payload. Mirrors the server's cap.
  @connect_opts [:binary, active: false, packet: :line, packet_size: 65_536]
  @timeout 5_000

  @doc """
  Runs the `status` command. `opts` is the parsed global option keyword
  list; `:socket` overrides the control channel path (defaults to
  `ControlSocket.path/0`), `:format` selects text or json output.
  """
  @spec run(keyword()) :: {iodata(), iodata(), 0 | 1 | 3}
  def run(opts) do
    path = opts[:socket] || ControlSocket.path()
    format = Keyword.get(opts, :format, "text")

    case :gen_tcp.connect({:local, path}, 0, @connect_opts, @timeout) do
      {:ok, socket} -> fetch_status(socket, path, format)
      {:error, _reason} -> not_reachable(path)
    end
  end

  @spec fetch_status(port(), String.t(), String.t()) :: {iodata(), iodata(), 0 | 1}
  defp fetch_status(socket, path, format) do
    with :ok <- :gen_tcp.send(socket, "status\n"),
         {:ok, line} <- :gen_tcp.recv(socket, 0, @timeout),
         {:ok, %{"assets" => _} = payload} <- Jason.decode(line) do
      render(payload, format)
    else
      _ -> malformed_response(path)
    end
  after
    :gen_tcp.close(socket)
  end

  @spec render(map(), String.t()) :: {iodata(), iodata(), 0}
  defp render(payload, "json"), do: {Jason.encode!(payload) <> "\n", "", 0}
  defp render(payload, _text), do: {render_text(payload), "", 0}

  @spec render_text(map()) :: [String.t()]
  defp render_text(%{"assets" => assets}) do
    table = [@columns | Enum.map(assets, &row/1)]
    widths = column_widths(table)

    Enum.map(table, &(format_row(&1, widths) <> "\n"))
  end

  @spec row(map()) :: [String.t()]
  defp row(asset) do
    [
      to_display(asset["name"]),
      to_display(asset["provider"]),
      to_display(asset["interval"]),
      render_last_update(asset["last_update"]),
      to_display(asset["state"])
    ]
  end

  defp render_last_update(nil), do: "never"
  defp render_last_update(iso), do: iso

  defp to_display(nil), do: "-"
  defp to_display(value), do: to_string(value)

  @spec column_widths([[String.t()]]) :: [non_neg_integer()]
  defp column_widths(rows) do
    Enum.map(0..(length(@columns) - 1), fn i ->
      rows |> Enum.map(&(&1 |> Enum.at(i) |> String.length())) |> Enum.max()
    end)
  end

  @spec format_row([String.t()], [non_neg_integer()]) :: String.t()
  defp format_row(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map(fn {cell, width} -> String.pad_trailing(cell, width) end)
    |> Enum.join("  ")
    |> String.trim_trailing()
  end

  @spec not_reachable(String.t()) :: {iodata(), iodata(), 3}
  defp not_reachable(path), do: {"", "error: daemon not reachable at #{path}\n", 3}

  @spec malformed_response(String.t()) :: {iodata(), iodata(), 1}
  defp malformed_response(_path), do: {"", "error: malformed response from daemon\n", 1}
end
