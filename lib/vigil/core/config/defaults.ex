defmodule Vigil.Core.Config.Defaults do
  @moduledoc """
  Validated `Defaults` CRD. See RFC-0003 §5.4.
  """

  @enforce_keys [:name, :interval]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          interval: String.t()
        }
end
