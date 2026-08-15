defmodule RunicAI.Steps.AssembleTurnPromptTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Message
  alias RunicAI.Prompt

  test "assembles a repaired prompt from a turn request" do
    state =
      State.new!(
        messages: [
          Message.new!(:system, "Pinned"),
          Message.new!(:system, "Pinned"),
          Message.new!(:assistant, "Earlier answer")
        ]
      )

    turn_request =
      TurnRequest.new!(state,
        input_message: "Hello",
        model: "test:model",
        observations: [Message.new!(:assistant, "")]
      )

    step = RunicAI.Steps.AssembleTurnPrompt.new(name: :assemble_prompt)
    workflow = Runic.workflow(name: :assemble_turn_prompt, steps: [step])
    workflow = Workflow.react_until_satisfied(workflow, turn_request)

    [prompt] = Workflow.raw_productions(workflow)

    assert %Prompt{} = prompt
    assert Enum.map(prompt.messages, & &1.content) == ["Pinned", "Earlier answer", "Hello"]
  end
end
