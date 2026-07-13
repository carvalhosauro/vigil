defmodule Vigil.TestSupport do
  @moduledoc """
  Shared setup helpers for tests that exercise config loading, providers, or
  notifiers — centralizes the `System`/`Application` env boilerplate that used
  to be duplicated across test files, each with its own `on_exit` cleanup.

  Every helper here registers its own `on_exit/1` cleanup, so a test (or its
  `setup` block) can call the ones it needs without hand-rolling teardown.

  See `Vigil.RuntimeCase` for the case template built on top of
  `put_telegram_env/0` and `put_log_notifier/0` — the default for any test
  that boots a real runtime tree.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @telegram_token "tok"
  @chat_id "123"
  @log_notifiers %{"telegram" => Vigil.Adapters.Notifier.Log}

  @doc """
  Sets `TELEGRAM_TOKEN` and `CHAT_ID` so a loaded config resolves its
  `${ENV_VAR}` references without a `:missing_env_vars` error.
  """
  @spec put_telegram_env() :: :ok
  def put_telegram_env do
    System.put_env("TELEGRAM_TOKEN", @telegram_token)
    System.put_env("CHAT_ID", @chat_id)

    on_exit(fn ->
      System.delete_env("TELEGRAM_TOKEN")
      System.delete_env("CHAT_ID")
    end)

    :ok
  end

  @doc """
  Stubs the provider registry so `name` (default `"yahoo"`) resolves to
  `module` instead of a real adapter.
  """
  @spec put_provider(module(), String.t()) :: :ok
  def put_provider(module, name \\ "yahoo") do
    Application.put_env(:vigil, :providers, %{name => module})
    on_exit(fn -> Application.delete_env(:vigil, :providers) end)
    :ok
  end

  @doc """
  Stubs the notifier registry with `notifiers` (a `%{action_name => module}`
  map). Call this again after `Vigil.RuntimeCase`'s default to override it
  with a test-specific stub notifier — the later call wins.
  """
  @spec put_notifiers(%{optional(String.t()) => module()}) :: :ok
  def put_notifiers(notifiers) do
    Application.put_env(:vigil, :notifiers, notifiers)
    on_exit(fn -> Application.delete_env(:vigil, :notifiers) end)
    :ok
  end

  @doc """
  Stubs `"telegram"` to the local `Vigil.Adapters.Notifier.Log` adapter — the
  load-bearing default: a booted runtime tree never dispatches to the real
  Telegram adapter (and never makes a live HTTP call to api.telegram.org)
  unless a test deliberately opts back in.
  """
  @spec put_log_notifier() :: :ok
  def put_log_notifier, do: put_notifiers(@log_notifiers)
end
