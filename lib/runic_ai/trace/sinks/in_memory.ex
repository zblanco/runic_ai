defmodule RunicAI.Trace.Sinks.InMemory do
  @moduledoc """
  Pure in-memory trace sink that accumulates events in a list.
  """

  @behaviour RunicAI.Trace.Sink

  alias RunicAI.Trace.Event

  @impl true
  def emit(%Event{} = event, state) when is_list(state) do
    {:ok, state ++ [event]}
  end

  def emit(%Event{} = event, _state), do: {:ok, [event]}

  @impl true
  def flush(state), do: {:ok, state}

  @spec events(term()) :: [Event.t()]
  def events(state) when is_list(state), do: Enum.filter(state, &match?(%Event{}, &1))
  def events(_state), do: []
end
