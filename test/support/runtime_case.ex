defmodule Vigil.RuntimeCase do
  @moduledoc """
  Case template for tests that boot a real runtime tree
  (`Vigil.Runtime.Supervisor` or any of its children).

  Applies `Vigil.TestSupport.put_telegram_env/0` and
  `Vigil.TestSupport.put_log_notifier/0` before every test — so a booted
  config always resolves, and a satisfied rule's `"telegram"` action always
  dispatches to the local `Log` adapter instead of the real one (no live HTTP
  call to api.telegram.org).

  The default is overridable: a test's own `setup` (or the test body itself)
  can call `Vigil.TestSupport.put_notifiers/1` again with its own stub — case
  template callbacks run first, so a later call always wins.
  """

  use ExUnit.CaseTemplate

  alias Vigil.TestSupport

  using do
    quote do
      alias Vigil.TestSupport
    end
  end

  setup do
    TestSupport.put_telegram_env()
    TestSupport.put_log_notifier()
    :ok
  end
end
