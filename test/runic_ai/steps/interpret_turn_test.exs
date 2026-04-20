defmodule RunicAI.Steps.InterpretTurnTest do
  use ExUnit.Case, async: true

  alias RunicAI.Error
  alias RunicAI.LLM.TestClient
  alias RunicAI.Steps.InterpretTurn

  test "interprets normal results as replies" do
    llm_result = TestClient.result("Hello")

    assert {:ok, turn_result} = InterpretTurn.interpret(llm_result, [])
    assert turn_result.kind == :reply
    assert turn_result.message.content == "Hello"
  end

  test "interprets matching patterns as finals" do
    llm_result = TestClient.result("DONE")

    assert {:ok, turn_result} = InterpretTurn.interpret(llm_result, final_pattern: "DONE")
    assert turn_result.kind == :final
  end

  test "wraps generate-time errors as error turn results" do
    error = Error.provider("provider failed")

    assert {:ok, turn_result} = InterpretTurn.interpret({:error, error}, [])
    assert turn_result.kind == :error
  end

  test "interprets provider tool calls as tool_requests" do
    response =
      TestClient.tool_response([
        TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")
      ])

    assert {:ok, llm_result} = RunicAI.LLM.Result.from_req_llm_response(response)
    assert {:ok, turn_result} = InterpretTurn.interpret(llm_result, [])

    assert turn_result.kind == :tool_requests

    assert [%{id: "call_1", name: "get_weather", arguments: %{"location" => "Paris"}}] =
             turn_result.details.tool_calls
  end
end
