defmodule RunicAI.Conversation.StateTest do
  use ExUnit.Case, async: true

  alias RunicAI.Conversation.State
  alias RunicAI.LLM.TestClient
  alias RunicAI.Message

  test "builds state from initial messages" do
    state = State.new!([Message.new!(:system, "You are helpful")])

    assert state.turns == 0
    assert length(state.messages) == 1
    assert state.status == :running
  end

  test "appends a user/assistant turn" do
    state = State.new!()
    result = TestClient.result("Hi there!")

    assert {:ok, updated_state} = State.append_turn(state, "Hello", result)

    assert updated_state.turns == 1
    assert length(updated_state.messages) == 2
    assert updated_state.last_assistant_message.content == "Hi there!"
  end
end
