defmodule Vigil.Core.State.NotificationStatus do
  @moduledoc """
  Per-rule notification timing for cooldown. Policy enforced in Phase 7.
  """

  defstruct last_notified_at: nil

  @type t :: %__MODULE__{
          last_notified_at: DateTime.t() | nil
        }
end
