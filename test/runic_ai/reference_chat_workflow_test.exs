defmodule RunicAI.ReferenceChatWorkflowTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Conversation.State
  alias RunicAI.LLM.Result
  alias RunicAI.LLM.TestClient
  alias RunicAI.Message

  test "composes prompt building, generation, and conversation accumulation" do
    extract_user = Runic.step(fn %{user: user} -> user end, name: :extract_user)
    prompt_builder = RunicAI.Steps.PromptBuilder.new(name: :build_prompt)

    llm_generate =
      RunicAI.Steps.LLMGenerate.new(
        name: :generate,
        model: "test:fake",
        client: TestClient.client("Hello back")
      )

    build_turn =
      Runic.step(
        fn user, {:ok, %Result{} = result} ->
          %{messages: [Message.new!(:user, user), result.message]}
        end,
        name: :build_turn
      )

    conversation = RunicAI.Conversation.new(name: :conversation, system: "You are helpful")

    workflow =
      Workflow.new(name: :reference_chat)
      |> Workflow.add(extract_user)
      |> Workflow.add(prompt_builder)
      |> Workflow.add(llm_generate, to: :build_prompt)
      |> Workflow.add(build_turn, to: [:extract_user, :generate])
      |> Workflow.add(conversation, to: :build_turn)
      |> Workflow.react_until_satisfied(%{system: "You are helpful", user: "Hello"})

    state =
      workflow
      |> Workflow.raw_productions()
      |> Enum.filter(&match?(%State{}, &1))
      |> Enum.max_by(& &1.turns)

    assert state.turns == 1
    assert Enum.map(state.messages, & &1.role) == [:system, :user, :assistant]
    assert state.last_assistant_message.content == "Hello back"
  end
end
