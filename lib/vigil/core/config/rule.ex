defmodule Vigil.Core.Config.Rule do
  @moduledoc """
  Validated `Rule` CRD. See RFC-0003 §5.2.

  The `condition` field holds the normalized `when` block from the resource.
  """

  @enforce_keys [:name, :asset, :condition, :actions]

  @type action :: String.t()

  @type t :: %__MODULE__{
          name: String.t(),
          asset: String.t(),
          condition: map(),
          actions: [action()],
          cooldown: String.t() | nil
        }

  defstruct @enforce_keys ++ [cooldown: nil]
end
