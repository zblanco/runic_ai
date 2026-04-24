defmodule RunicAI.Trace.Sinks.Logger do
  @moduledoc """
  Logger-backed trace sink for lightweight operational debugging.
  """

  @behaviour RunicAI.Trace.Sink

  require Logger

  alias RunicAI.Trace.Event

  @impl true
  def emit(%Event{} = event, state) do
    level = state_value(state, :level, :debug)

    Logger.log(level, fn ->
      "[runic_ai.trace] kind=#{event.kind} recipe=#{inspect(event.recipe)} " <>
        "agent_id=#{inspect(event.agent_id)} status=#{inspect(event.status)}"
    end)

    {:ok, state}
  end

  @impl true
  def flush(state), do: {:ok, state}

  defp state_value(state, key, default) when is_map(state), do: Map.get(state, key, default)

  defp state_value(state, key, default) when is_list(state) do
    Keyword.get(state, key, default)
  end

  defp state_value(_state, _key, default), do: default
end
