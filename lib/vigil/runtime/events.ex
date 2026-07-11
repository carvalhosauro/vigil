defmodule Vigil.Runtime.Events do
  @moduledoc """
  Event emission (RFC-0009).

  In V1 the Event Bus IS the `:telemetry` layer (RFC-0009 DEC-008): every event
  is `:telemetry.execute([:vigil | name], measurements, metadata)`. Emission is
  fire-and-forget and never changes the result of a cycle (RFC-0009 DEC-003).
  """

  @spec emit([atom()], map(), map()) :: :ok
  def emit(name, measurements \\ %{}, metadata \\ %{}) when is_list(name) do
    :telemetry.execute([:vigil | name], measurements, metadata)
  end
end
