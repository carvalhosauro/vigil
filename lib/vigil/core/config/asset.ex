defmodule Vigil.Core.Config.Asset do
  @moduledoc """
  Validated `Asset` CRD. See RFC-0003 §5.1.
  """

  @enforce_keys [:name, :symbol, :provider, :interval]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          symbol: String.t(),
          provider: String.t(),
          interval: String.t()
        }
end
