defmodule RunicAI.Steps.AssembleTurnRequestTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest

  test "builds a turn request from workflow input" do
    step =
      RunicAI.Steps.AssembleTurnRequest.new(
        name: :assemble,
        system: "You are helpful",
        model: "test:model"
      )

    workflow = Runic.workflow(name: :assemble_turn_request, steps: [step])
    workflow = Workflow.react_until_satisfied(workflow, %{user: "Hello"})

    [turn_request] = Workflow.raw_productions(workflow)

    assert %TurnRequest{} = turn_request
    assert turn_request.state.conversation.messages |> hd() |> Map.get(:role) == :system
    assert turn_request.input_message.content == "Hello"
  end

  test "accepts an existing agent state" do
    state = State.new!(system: "You are helpful")
    step = RunicAI.Steps.AssembleTurnRequest.new(name: :assemble, model: "test:model")

    workflow = Runic.workflow(name: :assemble_turn_request_existing, steps: [step])
    workflow = Workflow.react_until_satisfied(workflow, %{state: state, user: "Hello"})

    [turn_request] = Workflow.raw_productions(workflow)

    assert turn_request.state == state
  end
end
