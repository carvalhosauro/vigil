defmodule Vigil.Runtime.Control do
  @moduledoc """
  The CLI↔daemon control channel (RFC-0010 §13, DEC-007).

  A Unix domain socket, owner-only (`0600`), line-based protocol: a client
  sends one line (`"status\\n"` or `"reload\\n"`), the server replies with one
  line of JSON and closes the connection. Unknown requests get a JSON error
  line and close.

  ## reload

  `"reload\\n"` calls `Vigil.Runtime.Reconciler.reconcile/0` — the single
  reconciliation path shared with a filesystem-triggered reload (RFC-0006
  §15, RFC-0010 §9, DEC-006). Control only relays the result; the `reload.*`
  events (RFC-0006 §14) are emitted by the Reconciler itself, not here.

    * success: `{"ok": true, "added": [...], "changed": [...], "removed": [...],
      "failed": [...]}`, the asset names classified from the applied summary
      — `added` is `started`, `removed` is `stopped`, `changed` is
      `restarted ++ updated`, `failed` is the asset names from
      `applied.failed` (config validation passed, but applying it to one or
      more assets did not — see `Vigil.Runtime.Reconciler` moduledoc for the
      `applied/0` shape). `failed` is non-empty independently of the other
      three: a "changed" asset whose restart failed appears in neither
      `changed` nor `added`/`removed`, only in `failed`.
    * a rejected reload (invalid on-disk config — the running configuration
      is left untouched): `{"ok": false, "error": "<reason>"}`.

  `reconcile/0` is a `GenServer.call`; a Reconciler that is dead or mid-restart
  turns that into an `:exit` in the caller. `safe_reconcile/0` catches it and
  answers with a JSON error line instead of crashing this client task (which
  would otherwise merely log, since each connection already runs isolated —
  but a clean error reply is friendlier to the CLI than a dropped connection).

  Started as the last child of `Vigil.Runtime.Supervisor`'s `:rest_for_one`
  tree, after `WorkersSupervisor`, so a `status` request never races worker
  boot: by the time this process accepts connections, every configured
  `AssetWorker` already exists (RFC-0015 §8).

  Each client connection is handled by a short-lived, unsupervised, unlinked
  task, so a slow or hostile client cannot block the accept loop; the accept
  loop itself runs in a separate linked process so a client crash never
  reaches it. A broken listen socket crashes the acceptor, and the linked
  `Control` stops so `:rest_for_one` restarts the whole channel with a fresh
  socket — the loop never silently dies leaving a dead acceptor behind.

  ## Trust model

  Access is gated by filesystem permissions only — there is no authentication
  on the channel (RFC-0010 §13). The socket file is `0600`, and the default
  paths sit in a private directory (`$XDG_RUNTIME_DIR`, `0700` per the XDG
  spec). Two assumptions hold for V1: a normal `umask` (so the brief window
  between bind and `chmod` never exposes the socket under the default paths),
  and a single daemon per socket path — `init/1` removes a stale socket file
  before binding, so pointing two daemons at one path lets the second clobber
  the first with no warning. The world-writable `tmp` fallback path (used only
  when `$XDG_RUNTIME_DIR` is unset) is best-effort; prefer `VIGIL_SOCKET` in a
  private directory for production.

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
  alias Vigil.Core.Config.Error
  alias Vigil.Core.State.Health
  alias Vigil.Runtime.{AssetWorker, Events, Reconciler, WorkersSupervisor}

  @worker_registry Vigil.Runtime.WorkerRegistry

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

    # `packet_size` caps the line buffer so a client sending an unbounded line
    # with no newline cannot exhaust the handler's memory (recv returns
    # `{:error, :emsgsize}`, which `handle_client/1` closes on). A status
    # request is a few bytes; 4 KiB is generous.
    listen_opts = [
      :binary,
      packet: :line,
      packet_size: 4_096,
      active: false,
      reuseaddr: true,
      ifaddr: {:local, path}
    ]

    case :gen_tcp.listen(0, listen_opts) do
      {:ok, listen_socket} ->
        :ok = File.chmod!(path, 0o600)
        {:ok, acceptor} = Task.start_link(fn -> accept_loop(listen_socket) end)
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

  # `accept_fun` is injectable so the transient/fatal error handling can be
  # driven directly in tests without inducing real socket faults.
  @doc false
  @spec accept_loop(port(), (port() -> {:ok, port()} | {:error, term()})) :: :ok | no_return()
  def accept_loop(listen_socket, accept_fun \\ &:gen_tcp.accept/1) do
    case accept_fun.(listen_socket) do
      {:ok, client} ->
        Task.start(fn -> handle_client(client) end)
        accept_loop(listen_socket, accept_fun)

      {:error, reason} ->
        case accept_error_action(reason) do
          :halt -> :ok
          :retry -> accept_loop(listen_socket, accept_fun)
          :crash -> exit({:accept_failed, reason})
        end
    end
  end

  @doc false
  # `:closed` is `terminate/2` closing the listen socket — a clean shutdown.
  # `:econnaborted` is a client that vanished before we accepted it —
  # transient, keep accepting. Anything else means the listen socket is
  # broken: crash so the linked `Control` stops and `:rest_for_one` restarts
  # the channel, rather than exiting `:normal` and leaving it dead.
  @spec accept_error_action(term()) :: :halt | :retry | :crash
  def accept_error_action(:closed), do: :halt
  def accept_error_action(:econnaborted), do: :retry
  def accept_error_action(_reason), do: :crash

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

  defp respond("reload", client) do
    :gen_tcp.send(client, Jason.encode!(reload_payload()) <> "\n")
  end

  defp respond(_other, client) do
    :gen_tcp.send(client, Jason.encode!(%{error: "unknown request"}) <> "\n")
  end

  defp reload_payload do
    case safe_reconcile() do
      {:ok, %{applied: applied}} -> reload_ok(applied)
      {:error, reason} -> %{ok: false, error: render_reject_reason(reason)}
    end
  end

  defp safe_reconcile do
    Reconciler.reconcile()
  catch
    :exit, reason -> {:error, {:reconciler_unavailable, reason}}
  end

  defp reload_ok(applied) do
    %{
      ok: true,
      added: applied.started,
      changed: applied.restarted ++ applied.updated,
      removed: applied.stopped,
      failed: Enum.map(applied.failed, fn {name, _action, _reason} -> name end)
    }
  end

  # `Vigil.CLI.ErrorRenderer` renders the same `Config.Error` shape with
  # full English messages, but it lives in the `Vigil.CLI` boundary group,
  # which `Vigil.Runtime` cannot depend on — this is a smaller, boundary-safe
  # rendering good enough for a control-channel diagnostic.
  @spec render_reject_reason(term()) :: String.t()
  defp render_reject_reason([%Error{} | _] = errors) do
    errors
    |> Enum.map(fn %Error{kind: kind, name: name, reason: reason} ->
      "#{kind}/#{name}: #{inspect(reason)}"
    end)
    |> Enum.join("; ")
  end

  defp render_reject_reason(reason), do: inspect(reason)

  defp status_payload do
    %{
      version: :vigil |> Application.spec(:vsn) |> to_string(),
      assets: WorkersSupervisor |> DynamicSupervisor.which_children() |> Enum.map(&asset_status/1)
    }
  end

  # A `DynamicSupervisor` does not track children by a caller-chosen id (RFC-0006
  # D2), so unlike the previous static `Supervisor`, the name here comes from the
  # worker's own state on the happy path, falling back to a
  # `Vigil.Runtime.WorkerRegistry` reverse lookup by pid when the worker cannot
  # answer (dead, restarting, or a `GenServer.call` timeout).
  defp asset_status({_id, pid, :worker, _modules}) when is_pid(pid) do
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
      offline_status(worker_name(pid), reason)
  end

  defp asset_status({_id, not_a_pid, :worker, _modules}) do
    offline_status("unknown", not_a_pid)
  end

  defp worker_name(pid) do
    case Registry.keys(@worker_registry, pid) do
      [name | _rest] -> name
      [] -> "unknown"
    end
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
