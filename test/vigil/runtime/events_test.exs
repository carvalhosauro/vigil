defmodule Vigil.Runtime.EventsTest do
  use ExUnit.Case, async: true

  alias Vigil.Runtime.Events

  test "emits telemetry events under the :vigil prefix" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vigil, :runtime, :cycle, :started]
      ])

    Events.emit([:runtime, :cycle, :started], %{}, %{asset: "petr4"})

    assert_receive {[:vigil, :runtime, :cycle, :started], ^ref, %{}, %{asset: "petr4"}}
  end

  test "measurements and metadata default to empty maps" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:vigil, :runtime, :recovered]])

    Events.emit([:runtime, :recovered])

    assert_receive {[:vigil, :runtime, :recovered], ^ref, %{}, %{}}
  end
end
