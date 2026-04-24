defmodule RunicAI.Recipes.ConversationalToolAgentTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Prompt
  alias RunicAI.Recipes.ConversationalToolAgent
  alias RunicAI.Tool.Definition

  test "executes a requested tool and appends a tool observation in one cycle" do
    weather_tool = weather_tool()

    client = fn _model, %Prompt{} = _prompt, opts ->
      assert length(opts[:tools]) == 1

      {:ok,
       RunicAI.LLM.TestClient.tool_response([
         RunicAI.LLM.TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")
       ])}
    end

    workflow =
      ConversationalToolAgent.new(
        model: "test:model",
        registry: [weather_tool],
        client: client
      )
      |> Workflow.react_until_satisfied(%{user: "What's the weather in Paris?"})

    state = ConversationalToolAgent.latest_state(workflow)
    turn_result = ConversationalToolAgent.latest_turn_result(workflow)
    [call_result] = ConversationalToolAgent.latest_tool_results(workflow)
    [observation] = ConversationalToolAgent.latest_observations(workflow)

    assert %TurnResult{kind: :tool_requests} = turn_result
    assert state.pending_action == nil
    assert Enum.map(state.conversation.messages, & &1.role) == [:user, :assistant, :tool]
    assert call_result.status == :ok
    assert observation.tool_name == "get_weather"
    assert List.last(state.conversation.messages).role == :tool

    assert state.conversation.messages |> Enum.at(1) |> Map.get(:metadata) |> Map.get(:tool_calls) !=
             nil
  end

  test "reacts until resolution across iterative tool-use turns" do
    weather_tool = weather_tool()

    client = fn _model, %Prompt{messages: messages}, _opts ->
      case Enum.find(messages, &(&1.role == :tool)) do
        nil ->
          {:ok,
           RunicAI.LLM.TestClient.tool_response(
             [
               RunicAI.LLM.TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")
             ],
             "Let me check."
           )}

        tool_message ->
          assert tool_message.content =~ "\"sunny\""
          {:ok, RunicAI.LLM.TestClient.result("Paris is sunny.")}
      end
    end

    workflow =
      ConversationalToolAgent.react_until_resolution(
        [
          model: "test:model",
          registry: [weather_tool],
          client: client
        ],
        %{user: "What's the weather in Paris?"}
      )

    state = ConversationalToolAgent.latest_state(workflow)

    assert ConversationalToolAgent.latest_turn_result(workflow).kind == :reply
    assert ConversationalToolAgent.latest_reply_text(workflow) == "Paris is sunny."
    assert state.conversation.turns == 2

    assert Enum.map(state.conversation.messages, & &1.role) == [
             :user,
             :assistant,
             :tool,
             :assistant
           ]
  end

  test "tool_requirement :required only forces tool choice before the first tool batch" do
    weather_tool = weather_tool()

    client = fn _model, %Prompt{messages: messages}, opts ->
      case Enum.find(messages, &(&1.role == :tool)) do
        nil ->
          assert opts[:tool_choice] == :required

          {:ok,
           RunicAI.LLM.TestClient.tool_response(
             [
               RunicAI.LLM.TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")
             ],
             "Let me check."
           )}

        tool_message ->
          assert tool_message.content =~ "\"sunny\""
          assert opts[:tool_choice] == :auto
          {:ok, RunicAI.LLM.TestClient.result("Paris is sunny.")}
      end
    end

    workflow =
      ConversationalToolAgent.react_until_resolution(
        [
          model: "test:model",
          registry: [weather_tool],
          client: client,
          tool_requirement: :required
        ],
        %{user: "What's the weather in Paris?"}
      )

    assert ConversationalToolAgent.latest_reply_text(workflow) == "Paris is sunny."
    assert ConversationalToolAgent.latest_turn_result(workflow).kind == :reply
  end

  defp weather_tool do
    Definition.new!(
      name: "get_weather",
      description: "Get the weather for a city",
      parameter_schema: [location: [type: :string, required: true]],
      executor: fn %{location: location} ->
        {:ok, %{location: location, forecast: "sunny"}}
      end
    )
  end
end
