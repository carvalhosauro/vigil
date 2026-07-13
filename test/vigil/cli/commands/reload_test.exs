defmodule Vigil.CLI.Commands.ReloadTest do
  use ExUnit.Case, async: false

  alias Vigil.CLI.Commands.Reload
  alias Vigil.CLI.Main

  # Unix `sun_path` is capped at ~108 bytes on Linux; a short `/tmp` name
  # (never the long per-session scratchpad path) keeps every socket bindable.
  defp tmp_socket_path do
    Path.join(System.tmp_dir!(), "vg-reload-#{System.unique_integer([:positive])}.sock")
  end

  # A throwaway raw listener standing in for a daemon that answers the
  # connection with a canned reply — exercises rendering without booting the
  # real runtime (the real end-to-end path is covered by control_test.exs).
  defp start_bogus_listener(path, reply) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, client} = :gen_tcp.accept(listen_socket)
        :gen_tcp.send(client, reply)
        :gen_tcp.close(client)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
      File.rm(path)
    end)

    {pid, listen_socket}
  end

  defp success_payload(added \\ [], changed \\ [], removed \\ [], failed \\ []) do
    %{
      "ok" => true,
      "added" => added,
      "changed" => changed,
      "removed" => removed,
      "failed" => failed
    }
  end

  describe "reachable daemon, successful reload" do
    test "text output renders added/changed/removed counts" do
      path = tmp_socket_path()
      payload = success_payload(["itub4"], ["petr4"], [])
      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {stdout, "", 0} = Reload.run(socket: path)
      assert IO.iodata_to_binary(stdout) == "reload: 1 added, 1 changed, 0 removed\n"
    end

    test "an empty diff renders zero counts" do
      path = tmp_socket_path()
      start_bogus_listener(path, Jason.encode!(success_payload()) <> "\n")

      assert {stdout, "", 0} = Reload.run(socket: path)
      assert IO.iodata_to_binary(stdout) == "reload: 0 added, 0 changed, 0 removed\n"
    end

    test "json output round-trips the daemon payload" do
      path = tmp_socket_path()
      payload = success_payload(["itub4"], [], ["vale3"])
      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {stdout, "", 0} = Reload.run(socket: path, format: "json")
      assert IO.iodata_to_binary(stdout) |> Jason.decode!() == payload
    end

    test "unknown --format falls back to text" do
      path = tmp_socket_path()
      start_bogus_listener(path, Jason.encode!(success_payload(["a"])) <> "\n")

      assert {stdout, "", 0} = Reload.run(socket: path, format: "xml")
      assert IO.iodata_to_binary(stdout) =~ "1 added"
    end
  end

  describe "successful reload with a partial apply failure" do
    test "text output still prints the summary, plus a warning on stderr, exit 1" do
      path = tmp_socket_path()
      payload = success_payload(["itub4"], [], [], ["vale3"])
      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {stdout, stderr, 1} = Reload.run(socket: path)
      assert IO.iodata_to_binary(stdout) == "reload: 1 added, 0 changed, 0 removed\n"
      assert IO.iodata_to_binary(stderr) == "warning: 1 assets failed to apply: vale3\n"
    end

    test "json output still prints the payload on stdout, plus a warning on stderr, exit 1" do
      path = tmp_socket_path()
      payload = success_payload([], ["petr4"], [], ["vale3", "itub4"])
      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {stdout, stderr, 1} = Reload.run(socket: path, format: "json")
      assert IO.iodata_to_binary(stdout) |> Jason.decode!() == payload
      assert IO.iodata_to_binary(stderr) == "warning: 2 assets failed to apply: vale3, itub4\n"
    end

    test "an empty failed list is the ordinary success path, exit 0" do
      path = tmp_socket_path()
      payload = success_payload(["itub4"])
      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {_stdout, "", 0} = Reload.run(socket: path)
    end
  end

  describe "rejected reload" do
    test "text output reports the error on stderr with exit 2" do
      path = tmp_socket_path()
      payload = %{"ok" => false, "error" => "Asset/petr4: missing required field \"symbol\""}
      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {"", stderr, 2} = Reload.run(socket: path)
      text = IO.iodata_to_binary(stderr)
      assert text =~ "error: reload rejected:"
      assert text =~ "missing required field"
    end

    test "json output puts the rejection payload on stderr with exit 2" do
      path = tmp_socket_path()
      payload = %{"ok" => false, "error" => "boom"}
      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {"", stderr, 2} = Reload.run(socket: path, format: "json")
      assert IO.iodata_to_binary(stderr) |> Jason.decode!() == payload
    end
  end

  describe "daemon not reachable" do
    test "no socket file at all exits 3" do
      path = tmp_socket_path()
      refute File.exists?(path)

      assert {"", stderr, 3} = Reload.run(socket: path)
      assert IO.iodata_to_binary(stderr) =~ "daemon not reachable"
      assert IO.iodata_to_binary(stderr) =~ path
    end

    test "a stale socket file with no listener exits 3" do
      path = tmp_socket_path()
      File.write!(path, "stale")
      on_exit(fn -> File.rm(path) end)

      assert {"", stderr, 3} = Reload.run(socket: path)
      assert IO.iodata_to_binary(stderr) =~ "daemon not reachable"
    end
  end

  describe "malformed daemon reply" do
    test "non-JSON reply exits 1" do
      path = tmp_socket_path()
      start_bogus_listener(path, "not json\n")

      assert {"", stderr, 1} = Reload.run(socket: path)
      assert IO.iodata_to_binary(stderr) =~ "malformed"
    end

    test "valid JSON missing the expected keys exits 1" do
      path = tmp_socket_path()
      start_bogus_listener(path, Jason.encode!(%{"ok" => true}) <> "\n")

      assert {"", stderr, 1} = Reload.run(socket: path)
      assert IO.iodata_to_binary(stderr) =~ "malformed"
    end

    test "an empty reply (connection closed with no bytes) exits 1" do
      path = tmp_socket_path()
      start_bogus_listener(path, "")

      assert {"", stderr, 1} = Reload.run(socket: path)
      assert IO.iodata_to_binary(stderr) =~ "malformed"
    end
  end

  describe "Main wiring" do
    test "Main.run(reload) returns the daemon-not-reachable tuple" do
      path = tmp_socket_path()
      assert {"", stderr, 3} = Main.run(["reload", "--socket", path])
      assert IO.iodata_to_binary(stderr) =~ "daemon not reachable"
    end

    test "Main.run(reload, --format json) is dispatched" do
      path = tmp_socket_path()
      payload = success_payload(["itub4"])
      start_bogus_listener(path, Jason.encode!(payload) <> "\n")

      assert {stdout, "", 0} = Main.run(["reload", "--socket", path, "--format", "json"])
      assert IO.iodata_to_binary(stdout) |> Jason.decode!() == payload
    end

    test "Main.run(reload) with an unknown --format is rejected before dispatch" do
      # `Main.dispatch/2` validates `--format` itself before reaching any
      # command, so this never reaches `Reload.run/1`'s own text-fallback
      # clause — that clause is exercised by calling `Reload.run/1` directly,
      # above.
      path = tmp_socket_path()
      assert {"", stderr, 1} = Main.run(["reload", "--socket", path, "--format", "bogus"])
      assert IO.iodata_to_binary(stderr) =~ "invalid --format"
    end
  end
end
