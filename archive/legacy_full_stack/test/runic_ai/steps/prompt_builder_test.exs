defmodule RunicAI.Steps.PromptBuilderTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias RunicAI.Message
  alias RunicAI.Prompt

  describe "PromptBuilder step" do
    test "builds a prompt with system and user messages" do
      step = RunicAI.Steps.PromptBuilder.new(name: :build)

      workflow = Runic.workflow(name: :test_build, steps: [step])

      workflow =
        Workflow.react_until_satisfied(workflow, %{
          system: "You are a helpful assistant",
          user: "What is Elixir?"
        })

      [prompt] = Workflow.raw_productions(workflow)

      assert %Prompt{} = prompt
      assert Enum.map(prompt.messages, & &1.role) == [:system, :user]
      assert Enum.at(prompt.messages, 1).content == "What is Elixir?"
    end

    test "builds a prompt without system message" do
      step = RunicAI.Steps.PromptBuilder.new(name: :build)

      workflow = Runic.workflow(name: :test_no_sys, steps: [step])

      workflow =
        Workflow.react_until_satisfied(workflow, %{user: "Hello"})

      [prompt] = Workflow.raw_productions(workflow)

      assert %Prompt{} = prompt
      assert length(prompt.messages) == 1
      assert hd(prompt.messages).role == :user
    end

    test "prepends history messages" do
      history = [
        ReqLLM.Context.user("First message"),
        Message.new!(:assistant, "First reply")
      ]

      step = RunicAI.Steps.PromptBuilder.new(name: :build)

      workflow = Runic.workflow(name: :test_history, steps: [step])

      workflow =
        Workflow.react_until_satisfied(workflow, %{
          system: "System",
          user: "Second message",
          history: history
        })

      [prompt] = Workflow.raw_productions(workflow)

      assert length(prompt.messages) == 4
      assert Enum.map(prompt.messages, & &1.role) == [:system, :user, :assistant, :user]
    end
  end
end
