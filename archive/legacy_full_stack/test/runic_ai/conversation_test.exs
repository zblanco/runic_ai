defmodule RunicAI.ConversationTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias RunicAI.Conversation.State
  alias RunicAI.LLM.TestClient
  alias RunicAI.Message

  describe "Conversation accumulator" do
    test "accumulates conversation turns" do
      convo = RunicAI.Conversation.new(name: :chat)

      workflow =
        Workflow.new(name: :test_convo)
        |> Workflow.add(convo)

      workflow =
        Workflow.react_until_satisfied(workflow, %{
          user: "Hello",
          assistant: "Hi there!"
        })

      state =
        workflow
        |> Workflow.raw_productions()
        |> Enum.filter(&match?(%State{}, &1))
        |> Enum.max_by(& &1.turns)

      assert %State{} = state
      assert state.turns == 1
      assert state.last_assistant_message.content == "Hi there!"

      assert length(state.messages) == 2
    end

    test "initializes with a system prompt" do
      convo = RunicAI.Conversation.new(name: :chat, system: "You are helpful")

      workflow =
        Workflow.new(name: :test_sys)
        |> Workflow.add(convo)

      workflow =
        Workflow.react_until_satisfied(workflow, %{
          user: "Hi",
          assistant: "Hello!"
        })

      state =
        workflow
        |> Workflow.raw_productions()
        |> Enum.filter(&match?(%State{}, &1))
        |> Enum.max_by(& &1.turns)

      assert Enum.map(state.messages, & &1.role) == [:system, :user, :assistant]
    end

    test "tracks multiple turns via successive reactions" do
      convo = RunicAI.Conversation.new(name: :chat)

      workflow =
        Workflow.new(name: :test_multi)
        |> Workflow.add(convo)

      workflow =
        workflow
        |> Workflow.react_until_satisfied(%{user: "First", assistant: "Reply 1"})
        |> Workflow.react_until_satisfied(%{user: "Second", assistant: "Reply 2"})

      state =
        workflow
        |> Workflow.raw_productions()
        |> Enum.max_by(& &1.turns)

      assert state.turns == 2
      assert state.last_assistant_message.content == "Reply 2"

      assert length(state.messages) == 4
    end

    test "accepts normalized messages and LLM results" do
      convo = RunicAI.Conversation.new(name: :chat)

      workflow =
        Workflow.new(name: :test_messages)
        |> Workflow.add(convo)

      workflow =
        workflow
        |> Workflow.react_until_satisfied(%{
          messages: [Message.new!(:user, "Hello"), Message.new!(:assistant, "Hi there!")]
        })
        |> Workflow.react_until_satisfied(%{
          user: "How are you?",
          assistant: TestClient.result("Doing well!")
        })

      state =
        workflow
        |> Workflow.raw_productions()
        |> Enum.max_by(& &1.turns)

      assert state.turns == 2
      assert state.last_assistant_message.content == "Doing well!"
    end

    test "max_turns_reached? helper" do
      state = State.new!([], turns: 5)
      assert RunicAI.Conversation.max_turns_reached?(state, 5)
      refute RunicAI.Conversation.max_turns_reached?(state, 10)
    end

    test "stop_pattern_detected? helper" do
      state =
        State.new!(
          [Message.new!(:assistant, "I'm done. STOP")],
          turns: 1,
          last_assistant_message: Message.new!(:assistant, "I'm done. STOP")
        )

      assert RunicAI.Conversation.stop_pattern_detected?(state, "STOP")
      refute RunicAI.Conversation.stop_pattern_detected?(state, "QUIT")
    end

    test "stop_pattern_detected? returns false when no response yet" do
      state = State.new!()
      refute RunicAI.Conversation.stop_pattern_detected?(state, "STOP")
    end
  end
end
