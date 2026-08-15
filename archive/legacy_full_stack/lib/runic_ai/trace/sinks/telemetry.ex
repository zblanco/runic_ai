defmodule RunicAI.Trace.Sinks.Telemetry do
  @moduledoc """
  `:telemetry` bridge over `RunicAI.Trace.Event`.
  """

  @behaviour RunicAI.Trace.Sink

  alias RunicAI.Trace.Event

  @default_prefix [:runic_ai, :trace]

  @impl true
  def emit(%Event{} = event, state) do
    prefix = state_value(state, :prefix, @default_prefix)

    :telemetry.execute(
      prefix ++ [event.kind],
      Map.merge(%{count: 1}, event.measurements || %{}),
      %{
        event: event,
        recipe: event.recipe,
        agent_id: event.agent_id,
        conversation_id: event.conversation_id,
        status: event.status
      }
    )

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
