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

  test "resolves tool loops when the tool request assistant message has no text" do
    parent = self()

    status_tool =
      Definition.new!(
        name: "get_rollout_status",
        description: "Get rollout status for a project",
        parameter_schema: [project: [type: :string, required: true]],
        executor: fn %{project: project} ->
          {:ok, %{project: project, rollout: "paused", reason: "health check failed"}}
        end
      )

    client = fn _model, prompt, opts ->
      send(parent, {:llm_opts_seen, opts})

      messages = prompt.messages

      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, RunicAI.LLM.TestClient.result("Lantern is paused because the health check failed.")}
      else
        tool_call = RunicAI.LLM.TestClient.tool_call("get_rollout_status", %{project: "Lantern"})
        {:ok, RunicAI.LLM.TestClient.tool_response([tool_call])}
      end
    end

    workflow =
      MemoryAwareToolAgent.react_until_resolution(
        [
          model: "test:model",
          system: "Use tools when needed.",
          registry: [status_tool],
          tool_requirement: :required,
          client: client
        ],
        %{user: "Check Lantern and tell me what to do next.", focus: nil}
      )

    assert MemoryAwareToolAgent.latest_reply_text(workflow) =~ "Lantern is paused"
    assert MemoryAwareToolAgent.latest_tool_results(workflow) != nil

    assert_receive {:llm_opts_seen, first_opts}
    assert_receive {:llm_opts_seen, second_opts}
    refute Keyword.has_key?(first_opts, :focus)
    refute Keyword.has_key?(second_opts, :focus)
  end
end
