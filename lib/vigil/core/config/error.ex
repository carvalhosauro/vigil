defmodule Vigil.Core.Config.Error do
  @moduledoc """
  Typed configuration validation error for a single CRD resource.

  See RFC-0003 §9 and RFC-0013 §12.
  """

  @enforce_keys [:kind, :name, :reason]
  defstruct @enforce_keys

  @type reason ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:invalid_type, String.t(), String.t()}
          | {:invalid_value, String.t(), term()}
          | {:invalid_name, String.t()}
          | {:duplicate_name, String.t()}
          | {:unknown_reference, String.t(), String.t()}
          | {:unsupported_api_version, String.t()}
          | {:unsupported_kind, String.t()}
          | {:missing_interval, :no_defaults | :no_system_default}

  @type t :: %__MODULE__{
          kind: String.t(),
          name: String.t() | nil,
          reason: reason()
        }
end
