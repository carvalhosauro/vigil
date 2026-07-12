defmodule Vigil.CLI do
  @moduledoc """
  The command-line interface (RFC-0010).

  The operator's entry point: validating configuration, starting the daemon,
  inspecting state, and triggering reloads. An interface to the running
  system, never a place where business logic lives (RFC-0010 DEC-001) — it
  delegates to `Vigil.Adapters` and `Vigil.Core`, never to `Vigil.Runtime`
  internals.
  """
  use Boundary,
    top_level?: true,
    deps: [Vigil.Adapters, Vigil.Core],
    exports: [Main]
end
