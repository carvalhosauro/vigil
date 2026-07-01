defmodule Vigil.Core.State.RuleStatus do
  @moduledoc """
  Per-rule satisfaction for notification dedup. See RFC-0007 §9.
  """

  defstruct satisfied: false

  @type t :: %__MODULE__{
          satisfied: boolean()
        }
end
