defmodule Vigil.Adapters do
  @moduledoc """
  Adapters — the impure edge between Vigil and the outside world.

  Providers, notifiers, config loading and file watching live here. Adapters may
  use external dependencies and may depend on `Vigil.Core`, but never the reverse
  (enforced by `Boundary`). See RFC-0004, RFC-0006, RFC-0007.
  """
  use Boundary, top_level?: true, deps: [Vigil.Core], exports: []
end
