defmodule RunicAI.Steps.InterpretToolRequestsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.TurnResult
  alias RunicAI.LLM.TestClient
  alias RunicAI.Message
  alias RunicAI.Steps.InterpretToolRequests
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry
  alias RunicAI.Tool.Selection

  test "normalizes raw tool calls into validated call requests" do
    turn_result =
      TurnResult.tool_requests!(
        Message.new!(:assistant, ""),
        details: %{
          tool_calls: [
            ReqLLM.ToolCall.to_map(
              TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")
            )
          ]
        }
      )

    weather =
      Definition.new!(
        name: "get_weather",
        description: "Get weather",
        parameter_schema: [location: [type: :string, required: true]],
        executor: fn _args -> {:ok, "sunny"} end
      )

    selection = Selection.new!(Registry.new!([weather]), [weather])

    assert {:ok, normalized_turn_result} = InterpretToolRequests.normalize(turn_result, selection)

    [call_request] = normalized_turn_result.details.tool_calls
    assert call_request.tool_name == "get_weather"
    assert call_request.arguments == %{location: "Paris"}
  end

  test "returns an error turn result when the requested tool is not visible" do
    turn_result =
      TurnResult.tool_requests!(
        Message.new!(:assistant, ""),
        details: %{tool_calls: [%{id: "call_1", name: "missing_tool", arguments: %{}}]}
      )

    selection = Selection.new!(Registry.new!(), [])

    normalized_turn_result = InterpretToolRequests.normalize!(turn_result, selection)

    assert normalized_turn_result.kind == :error
    assert normalized_turn_result.details.phase == :interpret_tool_requests
  end
end
