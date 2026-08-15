defmodule RunicAI.Agent.TurnResultTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.TurnResult
  alias RunicAI.Error
  alias RunicAI.LLM.TestClient

  test "builds a reply result from an llm result" do
    llm_result = TestClient.result("Hello")

    assert {:ok, turn_result} = TurnResult.reply(llm_result, details: %{source: :test})

    assert turn_result.kind == :reply
    assert turn_result.message.content == "Hello"
    assert turn_result.details == %{source: :test}
  end

  test "builds a final result" do
    assert {:ok, turn_result} = TurnResult.final("DONE")

    assert turn_result.kind == :final
    assert turn_result.message.content == "DONE"
  end

  test "wraps errors as turn results" do
    error = Error.validation("bad input")

    assert {:ok, turn_result} = TurnResult.error(error)

    assert turn_result.kind == :error
    assert match?(%Error{}, turn_result.details.error)
  end

  test "builds a tool_requests result" do
    llm_result = TestClient.result("")

    assert {:ok, turn_result} =
             TurnResult.tool_requests(llm_result, details: %{tool_calls: [%{id: "call_1"}]})

    assert turn_result.kind == :tool_requests
    assert TurnResult.tool_requests?(turn_result)
    assert turn_result.message.role == :assistant
  end
end
