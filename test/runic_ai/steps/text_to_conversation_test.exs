defmodule RunicAI.Steps.TextToConversationTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias RunicAI.Message

  describe "TextToConversation step" do
    test "converts a user/assistant pair to normalized messages" do
      step = RunicAI.Steps.TextToConversation.new(name: :to_convo)

      workflow = Runic.workflow(name: :test_pair, steps: [step])

      workflow =
        Workflow.react_until_satisfied(workflow, %{
          user: "Hello",
          assistant: "Hi there!"
        })

      [messages] = Workflow.raw_productions(workflow)

      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 1).content == "Hi there!"
    end

    test "converts a turns list to normalized messages" do
      step = RunicAI.Steps.TextToConversation.new(name: :to_convo)

      workflow = Runic.workflow(name: :test_turns, steps: [step])

      workflow =
        Workflow.react_until_satisfied(workflow, %{
          turns: [
            {:system, "You are helpful"},
            {:user, "Hi"},
            {:assistant, "Hello!"},
            {:user, "How are you?"}
          ]
        })

      [messages] = Workflow.raw_productions(workflow)

      assert length(messages) == 4
      assert Enum.at(messages, 0).role == :system
      assert Enum.at(messages, 1).role == :user
      assert Enum.at(messages, 2).role == :assistant
      assert Enum.at(messages, 3).role == :user
    end

    test "normalizes pre-built message values" do
      step = RunicAI.Steps.TextToConversation.new(name: :to_convo)

      workflow = Runic.workflow(name: :test_messages, steps: [step])

      workflow =
        Workflow.react_until_satisfied(workflow, %{
          messages: [ReqLLM.Context.user("Hi"), Message.new!(:assistant, "Hello!")]
        })

      [messages] = Workflow.raw_productions(workflow)

      assert Enum.map(messages, & &1.role) == [:user, :assistant]
    end
  end
end
