defmodule RunicAI.Recipes.MemoryAwareToolAgentTest do
  use ExUnit.Case, async: true

  alias RunicAI.Recipes.MemoryAwareToolAgent
  alias RunicAI.Tool.Definition

  test "resolves a tool loop while keeping context and memory state" do
    weather_tool =
      Definition.new!(
        name: "get_weather",
        description: "Get weather for a city",
        parameter_schema: [location: [type: :string, required: true]],
        executor: fn %{location: location} ->
          {:ok, %{location: location, forecast: "sunny"}}
        end
      )

    client = fn _model, prompt, _opts ->
      messages = prompt.messages

      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, RunicAI.LLM.TestClient.result("The weather in Paris is sunny.")}
      else
        tool_call = RunicAI.LLM.TestClient.tool_call("get_weather", %{location: "Paris"})
        {:ok, RunicAI.LLM.TestClient.tool_response([tool_call], "Checking weather")}
      end
    end

    workflow =
      MemoryAwareToolAgent.react_until_resolution(
        [
          model: "test:model",
          system: "Use tools when needed.",
          registry: [weather_tool],
          client: client
        ],
        %{user: "What's the weather in Paris?"}
      )

    state = MemoryAwareToolAgent.latest_state(workflow)

    assert MemoryAwareToolAgent.latest_reply_text(workflow) == "The weather in Paris is sunny."
    assert state.context != nil
    assert state.context.stats.memory_count >= 1
    assert MemoryAwareToolAgent.latest_tool_results(workflow) != nil
  end
end
