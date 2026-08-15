defmodule RunicAI.Component.LLMGenerateTest do
  use ExUnit.Case, async: true

  alias RunicAI.Component.LLMGenerate
  alias RunicAI.Contract.Component
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result
  alias RunicAI.Message
  alias RunicAI.Recipe.ChatTurn
  alias RunicAI.Testing.ScriptedClient

  test "component publishes exact request/result ports and keeps its binding out of the spec" do
    contract = LLMGenerate.contract()
    encoded = Component.encode(contract)

    assert [%{name: "request", direction: :input}] = contract.inputs
    assert [%{name: "result", direction: :output}] = contract.outputs
    assert encoded["implementation"]["id"] == "runic_ai.llm.generate"
    refute inspect(encoded) =~ "ScriptedClient"
  end

  test "direct component execution and the Runic recipe preserve owned outcomes" do
    request = Request.new!("test:model", "hello")
    expected = Result.new!(Message.assistant("world"))

    assert {:ok, ^expected} = LLMGenerate.run(request, ScriptedClient, script: expected)

    workflow = ChatTurn.new(ScriptedClient, script: expected)
    evaluated = Runic.Workflow.react_until_satisfied(workflow, request)

    assert {:ok, expected} in Runic.Workflow.raw_productions(evaluated)
  end
end
