defmodule RunicAI.Agent.StateTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Message

  test "initializes with a system message" do
    state = State.new!(system: "You are helpful")

    assert state.status == :running
    assert Enum.map(state.conversation.messages, & &1.role) == [:system]
  end

  test "applies a reply turn result into nested conversation state" do
    state = State.new!(system: "You are helpful")

    turn_request =
      TurnRequest.new!(state,
        input_message: "Hello",
        model: "test:model"
      )

    turn_result = TurnResult.reply!("Hi there!")

    updated_state = State.apply_turn_result!(state, turn_request, turn_result)

    assert updated_state.status == :running
    assert updated_state.last_turn_result.kind == :reply

    assert Enum.map(updated_state.conversation.messages, & &1.role) == [
             :system,
             :user,
             :assistant
           ]

    assert updated_state.conversation.last_assistant_message.content == "Hi there!"
  end

  test "marks final turns as completed" do
    state = State.new!()
    turn_request = TurnRequest.new!(state, input_message: "Done?", model: "test:model")
    turn_result = TurnResult.final!(Message.new!(:assistant, "DONE"))

    updated_state = State.apply_turn_result!(state, turn_request, turn_result)

    assert updated_state.status == :completed
  end
end
