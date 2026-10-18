defmodule Acervo.TelemetryHelpers do
  @moduledoc """
  Receives `:telemetry` events in a test, but only those emitted by the test
  process itself, so async tests never see each other's events.
  """

  @doc "Forwards `events` emitted by the calling process as `{event, measurements, metadata}`."
  def attach_own(events) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(id, events, &__MODULE__.forward/4, test)
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def forward(event, measurements, metadata, test) do
    if self() == test, do: send(test, {event, measurements, metadata})
  end
end
