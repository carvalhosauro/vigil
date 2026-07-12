defmodule Vigil.Runtime.Control do
  @moduledoc """
  The CLI↔daemon control channel (RFC-0010 §13, DEC-007).

  A Unix domain socket, owner-only (`0600`), line-based protocol: a client
  sends one line (`"status\\n"`), the server replies with one line of JSON and
  closes the connection. Unknown requests get a JSON error line and close.

  Started as the last child of `Vigil.Runtime.Supervisor`'s `:rest_for_one`
  tree, after `WorkersSupervisor`, so a `status` request never races worker
  boot: by the time this process accepts connections, every configured
  `AssetWorker` already exists (RFC-0015 §8).

  Each client connection is handled by a short-lived, unsupervised, unlinked
  task, so a slow or hostile client cannot block the accept loop; the accept
  loop itself runs in a separate linked process so a client crash never
  reaches it.

  ## Status heuristic (v1)

  Neither RFC-0011 nor RFC-0012 pin the online/degraded/offline mapping; this
  is a v1 heuristic documented here:

    * `online`   — a successful cycle has happened and `consecutive_failures == 0`
    * `degraded` — `consecutive_failures` in `1..2`
    * `offline`  — `consecutive_failures >= 3`, or the worker has never
      completed a successful cycle (`last_success == nil`), or the worker did
      not respond in time (dead, restarting, or a `GenServer.call` timeout)
  """

  use GenServer

  require Logger

  alias Vigil.Adapters.ControlSocket
  alias Vigil.Core.State.Health
  alias Vigil.Runtime.{AssetWorker, Events, WorkersSupervisor}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Keyword.get(opts, :path, ControlSocket.path())

    # Bind fails on an existing socket file — a stale file from an unclean
    # shutdown must be removed first.
    _ = File.rm(path)

    listen_opts = [:binary, packet: :line, active: false, reuseaddr: true, ifaddr: {:local, path}]

    case :gen_tcp.listen(0, listen_opts) do
      {:ok, listen_socket} ->
        :ok = File.chmod!(path, 0o600)
        parent = self()
        {:ok, acceptor} = Task.start_link(fn -> accept_loop(listen_socket, parent) end)
        {:ok, %{path: path, listen_socket: listen_socket, acceptor: acceptor}}

      {:error, reason} ->
        {:stop, {:listen_failed, path, reason}}
    end
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state) when reason != :normal do
    {:stop, {:acceptor_crashed, reason}, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{path: path, listen_socket: listen_socket}) do
    :gen_tcp.close(listen_socket)
    _ = File.rm(path)
    :ok
  end

  defp accept_loop(listen_socket, control_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client} ->
        Task.start(fn -> handle_client(client) end)
        accept_loop(listen_socket, control_pid)

      # `:closed` on a clean `terminate/2` shutdown, or any other error on a
      # broken listen socket — either way the loop has nothing left to do.
      {:error, _reason} ->
        :ok
    end
  end

  defp handle_client(client) do
    case :gen_tcp.recv(client, 0, 5_000) do
      {:ok, line} ->
        request = String.trim(line)
        Events.emit([:control, :request], %{}, %{request: request})
        respond(request, client)

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(client)
  end

  defp respond("status", client) do
    :gen_tcp.send(client, Jason.encode!(status_payload()) <> "\n")
  end

  defp respond(_other, client) do
    :gen_tcp.send(client, Jason.encode!(%{error: "unknown request"}) <> "\n")
  end

  defp status_payload do
    %{
      version: :vigil |> Application.spec(:vsn) |> to_string(),
      assets: WorkersSupervisor |> Supervisor.which_children() |> Enum.map(&asset_status/1)
    }
  end

  defp asset_status({{AssetWorker, name}, pid, :worker, _modules}) when is_pid(pid) do
    worker_state = AssetWorker.state(pid)
    asset = worker_state.asset
    health = worker_state.vigil_state.health

    %{
      name: asset.name,
      provider: asset.provider,
      interval: asset.interval,
      last_update: iso8601_or_nil(health.last_success),
      consecutive_failures: health.consecutive_failures,
      state: classify(health)
    }
  catch
    :exit, reason ->
      offline_status(name, reason)
  end

  defp asset_status({{AssetWorker, name}, not_a_pid, :worker, _modules}) do
    offline_status(name, not_a_pid)
  end

  defp offline_status(name, reason) do
    %{
      name: name,
      provider: nil,
      interval: nil,
      last_update: nil,
      consecutive_failures: nil,
      state: "offline",
      note: inspect(reason)
    }
  end

  defp classify(%Health{last_success: nil}), do: "offline"
  defp classify(%Health{consecutive_failures: 0}), do: "online"
  defp classify(%Health{consecutive_failures: n}) when n in 1..2, do: "degraded"
  defp classify(%Health{}), do: "offline"

  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
