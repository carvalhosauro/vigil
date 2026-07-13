defmodule Vigil.Runtime.Watcher do
  @moduledoc """
  Watches the configuration directory for filesystem changes and drives
  automatic reload (RFC-0006 §6, §13, §14).

  Subscribes to `FileSystem` events on the config directory — the same
  directory the Reconciler reloads from (passed in as an opt from
  `Runtime.Supervisor`, defaulting to `ConfigLoader.config_dir/0`; they MUST
  agree, or the Watcher would be triggering reloads of a directory the
  Reconciler never reads).

  A change is any create, modify, rename, or delete of a file under that
  directory. Rather than reconciling on every single event, each event
  (re)starts a short **debounce** timer; only once the quiet period elapses
  with no further events does the Watcher call `Reconciler.reconcile/0`. This
  collapses a burst from one logical change (an editor's write-then-rename, or
  several resource files edited together) into exactly one reload.

  `Reconciler.reconcile/0` already does the reject/log/keep-running-config
  work (RFC-0006 §13) and emits the `reload.*` events (§14) — the Watcher does
  not duplicate any of that, it only logs the outcome. Neither a rejected
  reload (`{:error, _}`) nor `reconcile/0` raising or exiting crashes the
  Watcher: it stays alive and keeps watching either way.

  Automatic reload is a non-critical convenience on top of the manual `vigil
  reload` path (RFC-0006 §15) — the two share the same `Reconciler.reconcile/0`
  call, but only the Watcher depends on a working OS-level file watch backend
  (`inotify` on Linux, FSEvents on macOS, or the portable, dependency-free
  `:fs_poll`). If that backend cannot start (e.g. `inotify-tools` is missing),
  `init/1` does not fail the Watcher, let alone the surrounding
  `Runtime.Supervisor` tree — it logs and comes up in a degraded, non-watching
  state instead. Manual reload keeps working either way.

  The watched directory, the debounce interval, and the reconcile/watch
  backend are all injectable via `start_link/1` opts so tests can drive the
  debounce logic deterministically with synthetic `:file_event` messages
  instead of depending on real filesystem timing. `:file_system_opts` is
  passed straight through to `FileSystem.start_link/1` (e.g. `backend:
  :fs_poll` on a platform without a native watcher backend).

  Without an explicit `:file_system_opts` override, `VIGIL_WATCHER_BACKEND=poll`
  forces the same `:fs_poll` backend (mirroring `ConfigLoader.config_dir/0`
  and `ControlSocket.path/0`'s own environment-variable escape hatches) —
  the operator-facing knob for a deployment target with no native watcher
  (no `inotify-tools`, no FSEvents). `VIGIL_WATCHER_POLL_INTERVAL_MS` tunes
  its poll interval (`file_system`'s own default is 1000ms).
  """

  use GenServer

  require Logger

  alias Vigil.Adapters.ConfigLoader
  alias Vigil.Runtime.Reconciler

  @debounce_ms 500

  @type reconcile_fun :: (-> {:ok, term()} | {:error, term()})
  @type start_watch_fun :: (String.t() -> {:ok, pid()} | {:error, term()})

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    dir = Keyword.get(opts, :config_dir, ConfigLoader.config_dir())
    debounce_ms = Keyword.get(opts, :debounce_ms, @debounce_ms)
    reconcile_fun = Keyword.get(opts, :reconcile_fun, &Reconciler.reconcile/0)
    file_system_opts = Keyword.get_lazy(opts, :file_system_opts, &default_file_system_opts/0)

    start_watch_fun =
      Keyword.get_lazy(opts, :start_watch_fun, fn ->
        fn dir -> default_start_watch(dir, file_system_opts) end
      end)

    state = %{
      dir: dir,
      debounce_ms: debounce_ms,
      reconcile_fun: reconcile_fun,
      backend_pid: nil,
      timer_ref: nil
    }

    case start_watch_fun.(dir) do
      {:ok, backend_pid} ->
        {:ok, %{state | backend_pid: backend_pid}}

      {:error, reason} ->
        # Non-fatal (see moduledoc): come up degraded rather than fail this
        # child, which under `:rest_for_one` would fail the whole Runtime
        # tree over something manual `vigil reload` doesn't even need.
        Logger.error(
          "watcher: failed to start file watch backend for #{dir}: #{inspect(reason)} — " <>
            "automatic reload is disabled, manual `vigil reload` is unaffected"
        )

        {:ok, state}
    end
  end

  # `VIGIL_WATCHER_BACKEND=poll` forces the portable `:fs_poll` backend (see
  # moduledoc) when the caller didn't already pick a backend via
  # `:file_system_opts` — an operator-facing fallback for a platform with no
  # native watcher, without requiring any code change or Elixir config.
  @spec default_file_system_opts() :: keyword()
  defp default_file_system_opts do
    case System.get_env("VIGIL_WATCHER_BACKEND") do
      "poll" -> [backend: :fs_poll] ++ poll_interval_opt()
      _ -> []
    end
  end

  @spec poll_interval_opt() :: keyword()
  defp poll_interval_opt do
    with value when is_binary(value) <- System.get_env("VIGIL_WATCHER_POLL_INTERVAL_MS"),
         {ms, ""} <- Integer.parse(value) do
      [interval: ms]
    else
      _ -> []
    end
  end

  # `file_system`'s own subscription model: a backend process delivers
  # `{:file_event, backend_pid, {path, events}}` (and `{:file_event,
  # backend_pid, :stop}`) to whichever process called `subscribe/1` — that's
  # this GenServer, since it calls `FileSystem.start_link/1` and immediately
  # subscribes itself.
  #
  # `file_system_opts` is merged in ahead of `dirs`, so an operator whose
  # platform lacks a native watcher (no `inotify-tools`, no FSEvents) can
  # force the portable `backend: :fs_poll` implementation — bundled with the
  # library, needs no external binary — via `Runtime.Supervisor`'s `:watcher`
  # passthrough opt, without any Vigil-specific config surface.
  @spec default_start_watch(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  defp default_start_watch(dir, file_system_opts) do
    fs_opts = Keyword.put(file_system_opts, :dirs, [dir])

    with {:ok, pid} <- FileSystem.start_link(fs_opts),
         :ok <- FileSystem.subscribe(pid) do
      {:ok, pid}
    else
      # `FileSystem.start_link/1` returns plain `:ignore` (not an `{:error,
      # _}` tuple) when its native backend fails to bootstrap (e.g. inotify
      # unavailable) — normalized here so `init/1` always sees `{:error, _}`.
      :ignore -> {:error, :file_system_backend_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # Any change under the watched dir (create/modify/rename/delete all arrive
  # this way — `file_system` does not distinguish them at this level, and
  # RFC-0006 §6 treats them identically) resets the debounce timer rather
  # than reconciling immediately. The originating pid is not checked against
  # `state.backend_pid`: a single Watcher only ever subscribes to one backend,
  # and pinning the match to a specific pid would only get in the way of
  # driving this clause directly with synthetic messages in tests.
  @impl GenServer
  def handle_info({:file_event, _pid, {_path, _events}}, state) do
    {:noreply, reset_debounce_timer(state)}
  end

  # `file_system` signals that its backend process stopped watching — no
  # further file events will ever arrive on this subscription. Continuing to
  # run would silently stop watching forever, so instead the Watcher stops
  # itself (a `:shutdown` reason, not a crash) and lets its supervisor restart
  # it with a fresh backend and a fresh subscription.
  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.warning("watcher: file_system backend stopped watching #{state.dir}; restarting")
    {:stop, {:shutdown, :file_system_backend_stopped}, state}
  end

  def handle_info(:debounced_reconcile, state) do
    run_reconcile(state)
    {:noreply, %{state | timer_ref: nil}}
  end

  @spec reset_debounce_timer(map()) :: map()
  defp reset_debounce_timer(%{timer_ref: nil} = state), do: schedule_debounce(state)

  defp reset_debounce_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    # If the timer already fired before this event was processed, its message
    # is sitting in the mailbox; cancel_timer can't remove it. Flush it so the
    # freshly scheduled timer is the only one that reconciles — otherwise a
    # `:file_event` landing right at expiry coalesces to two reconciles.
    receive do
      :debounced_reconcile -> :ok
    after
      0 -> :ok
    end

    schedule_debounce(state)
  end

  @spec schedule_debounce(map()) :: map()
  defp schedule_debounce(state) do
    ref = Process.send_after(self(), :debounced_reconcile, state.debounce_ms)
    %{state | timer_ref: ref}
  end

  # A rejected reload and `Reconciler.reconcile/0` itself misbehaving
  # (raising, exiting) are both handled here without crashing the Watcher
  # (RFC-0006 §13: keep running config, keep watching). The `reload.*` events
  # themselves are emitted by the Reconciler, not here — this only logs.
  @spec run_reconcile(map()) :: :ok
  defp run_reconcile(state) do
    case state.reconcile_fun.() do
      {:ok, _summary} ->
        Logger.info("watcher: automatic reload completed for #{state.dir}")

      {:error, reason} ->
        Logger.warning("watcher: automatic reload rejected for #{state.dir}: #{inspect(reason)}")
    end

    :ok
  rescue
    error ->
      Logger.error(
        "watcher: reconcile raised for #{state.dir}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  catch
    kind, reason ->
      Logger.error("watcher: reconcile #{kind} for #{state.dir}: #{inspect(reason)}")
      :ok
  end
end
