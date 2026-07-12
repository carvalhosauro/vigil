defmodule Vigil.Adapters.ControlSocketTest do
  use ExUnit.Case, async: false

  alias Vigil.Adapters.ControlSocket

  setup do
    on_exit(fn ->
      System.delete_env("VIGIL_SOCKET")
      System.delete_env("XDG_RUNTIME_DIR")
      Application.delete_env(:vigil, :socket_path)
    end)

    :ok
  end

  test "VIGIL_SOCKET wins over everything else" do
    System.put_env("VIGIL_SOCKET", "/tmp/from-env.sock")
    Application.put_env(:vigil, :socket_path, "/tmp/from-app-env.sock")
    System.put_env("XDG_RUNTIME_DIR", "/tmp/xdg")

    assert ControlSocket.path() == "/tmp/from-env.sock"
  end

  test "config :vigil, :socket_path wins over XDG_RUNTIME_DIR" do
    Application.put_env(:vigil, :socket_path, "/tmp/from-app-env.sock")
    System.put_env("XDG_RUNTIME_DIR", "/tmp/xdg")

    assert ControlSocket.path() == "/tmp/from-app-env.sock"
  end

  test "falls back to ${XDG_RUNTIME_DIR}/vigil.sock" do
    System.put_env("XDG_RUNTIME_DIR", "/tmp/xdg")

    assert ControlSocket.path() == "/tmp/xdg/vigil.sock"
  end

  test "falls back to a tmp_dir socket named after $USER when XDG_RUNTIME_DIR is unset" do
    System.delete_env("XDG_RUNTIME_DIR")
    user = System.get_env("USER")

    path = ControlSocket.path()

    assert path == Path.join(System.tmp_dir!(), "vigil-#{user}.sock")
  end

  test "falls back to the unix uid when $USER is unset" do
    System.delete_env("XDG_RUNTIME_DIR")
    user = System.get_env("USER")
    System.delete_env("USER")
    on_exit(fn -> if user, do: System.put_env("USER", user) end)

    path = ControlSocket.path()

    assert path =~ ~r{^#{Regex.escape(System.tmp_dir!())}/vigil-\d+\.sock$}
  end

  test "falls back to \"vigil\" when neither $USER nor `id -u` are available" do
    System.delete_env("XDG_RUNTIME_DIR")
    user = System.get_env("USER")
    path_env = System.get_env("PATH")
    System.delete_env("USER")
    # An empty PATH means `id` cannot be found: System.cmd/2 raises ErlangError.
    System.put_env("PATH", "")

    on_exit(fn ->
      if user, do: System.put_env("USER", user)
      System.put_env("PATH", path_env)
    end)

    assert ControlSocket.path() == Path.join(System.tmp_dir!(), "vigil-vigil.sock")
  end
end
