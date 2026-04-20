defmodule RunicAI.Steps.GenerateTurnTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.LLM.Result
  alias RunicAI.LLM.TestClient
  alias RunicAI.Steps.AssembleTurnPrompt
  alias RunicAI.Steps.GenerateTurn

  test "generates a turn from a turn request and prompt" do
    state = State.new!(system: "You are helpful")

    turn_request =
      TurnRequest.new!(state, input_message: "Hello", model: "test:model", client: TestClient)

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:ok, %Result{} = result} = GenerateTurn.generate(turn_request, prompt)
    assert Result.text(result) =~ "I received: Hello"
  end
end
