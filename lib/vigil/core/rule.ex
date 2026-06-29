defmodule Vigil.Core.Rule do
  @moduledoc """
  A monitoring rule: a condition over a `Vigil.Core.Context` and the actions to
  run when it is satisfied. See RFC-0001 and RFC-0003.

  The rule carries no business logic — it is data evaluated by
  `Vigil.Core.RuleEngine`.
  """

  @enforce_keys [:name, :asset, :condition, :actions]
  defstruct @enforce_keys

  @type action :: atom() | String.t()

  @type t :: %__MODULE__{
          name: String.t(),
          asset: String.t(),
          condition: map(),
          actions: [action()]
        }
end
