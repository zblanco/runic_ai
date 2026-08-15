defmodule RunicAI.Steps.RepairHistoryTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Message
  alias RunicAI.Steps.RepairHistory

  test "drops blank messages and deduplicates identical leading system messages" do
    messages = [
      Message.new!(:system, "sys"),
      Message.new!(:system, "sys"),
      Message.new!(:user, "hello"),
      Message.new!(:assistant, "")
    ]

    assert {:ok, repaired} = RepairHistory.repair(messages)
    assert Enum.map(repaired, & &1.content) == ["sys", "hello"]
  end

  test "repairs nested conversation inside agent state" do
    state =
      State.new!(
        messages: [
          Message.new!(:system, "sys"),
          Message.new!(:system, "sys"),
          Message.new!(:user, "hello"),
          Message.new!(:assistant, "")
        ]
      )

    assert {:ok, repaired_state} = RepairHistory.repair(state)
    assert Enum.map(repaired_state.conversation.messages, & &1.content) == ["sys", "hello"]
  end

  test "preserves blank assistant tool-call messages" do
    messages = [
      Message.new!(:assistant, "",
        metadata: %{tool_calls: [%{id: "call_1", name: "get_weather"}]}
      )
    ]

    assert {:ok, repaired} = RepairHistory.repair(messages)
    assert length(repaired) == 1
    assert hd(repaired).metadata.tool_calls == [%{id: "call_1", name: "get_weather"}]
  end
end
