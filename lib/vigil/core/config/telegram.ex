defmodule Vigil.Core.Config.Telegram do
  @moduledoc """
  Validated `Telegram` CRD. See RFC-0003 §5.3.
  """

  @enforce_keys [:name, :token, :chat_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          token: String.t(),
          chat_id: String.t()
        }
end
