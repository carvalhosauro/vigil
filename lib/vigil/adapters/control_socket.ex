defmodule Vigil.Adapters.ControlSocket do
  @moduledoc """
  Resolves the path of the CLI↔daemon control channel Unix domain socket
  (RFC-0010 §13, DEC-007).

  Lives in `Vigil.Adapters` (not `Vigil.Runtime`) so `Vigil.CLI` — which may
  not depend on `Vigil.Runtime` (RFC-0010 DEC-001) — can render the socket
  path in the `vigil start` banner without crossing the boundary.
  `Vigil.Runtime.Control` calls the same function, so both sides always agree
  on the path.

  Resolution order:

    1. `VIGIL_SOCKET` environment variable
    2. `config :vigil, :socket_path`
    3. `${XDG_RUNTIME_DIR}/vigil.sock`
    4. `System.tmp_dir!()/vigil-<uid or user>.sock` (XDG_RUNTIME_DIR unset)
  """

  @spec path() :: String.t()
  def path do
    System.get_env("VIGIL_SOCKET") ||
      Application.get_env(:vigil, :socket_path) ||
      xdg_socket() ||
      fallback_socket()
  end

  defp xdg_socket do
    case System.get_env("XDG_RUNTIME_DIR") do
      nil -> nil
      dir -> Path.join(dir, "vigil.sock")
    end
  end

  defp fallback_socket do
    Path.join(System.tmp_dir!(), "vigil-#{owner_id()}.sock")
  end

  # The control channel is a Unix domain socket (RFC-0010 §13): this whole
  # module — and therefore this fallback — only ever runs on Unix, so no
  # non-Unix branch is needed here.
  defp owner_id do
    System.get_env("USER") || unix_uid()
  end

  defp unix_uid do
    case System.cmd("id", ["-u"]) do
      {output, 0} -> String.trim(output)
      _ -> "vigil"
    end
  rescue
    ErlangError -> "vigil"
  end
end
