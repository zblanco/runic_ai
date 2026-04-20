defmodule RunicAI.Rules.ContinueChatTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Message
  alias RunicAI.Rules.ContinueChat

  test "stops on max turns" do
    state =
      State.new!(
        messages: [Message.new!(:assistant, "hello")],
        status: :running
      )

    # turn count inferred from assistant messages above
    turn_result = TurnResult.reply!("hello")

    assert {:ok, decision} = ContinueChat.decide(state, turn_result, max_turns: 1)
    assert decision.action == :stop
    assert decision.reason == :max_turns
  end

  test "stops when stop pattern appears in the latest assistant message" do
    state =
      State.new!(
        messages: [Message.new!(:assistant, "STOP")],
        status: :running
      )

    turn_result = TurnResult.reply!("STOP")

    assert {:ok, decision} = ContinueChat.decide(state, turn_result, stop_pattern: "STOP")
    assert decision.action == :stop
    assert decision.reason == :stop_pattern
  end

  test "honors a custom continuation predicate" do
    state = State.new!()
    turn_result = TurnResult.reply!("hello")

    assert {:ok, decision} =
             ContinueChat.decide(state, turn_result,
               continue_when: fn _state, _turn_result -> :halt end
             )

    assert decision.action == :halt
  end
end
