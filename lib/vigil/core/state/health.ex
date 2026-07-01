defmodule Vigil.Core.State.Health do
  @moduledoc """
  Runtime health counters persisted across cycles. See RFC-0012 §4.
  """

  defstruct consecutive_failures: 0, last_success: nil

  @type t :: %__MODULE__{
          consecutive_failures: non_neg_integer(),
          last_success: DateTime.t() | nil
        }
end
