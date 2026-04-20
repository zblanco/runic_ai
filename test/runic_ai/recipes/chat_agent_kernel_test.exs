defmodule RunicAI.Recipes.ChatAgentKernelTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Prompt
  alias RunicAI.Recipes.ChatAgentKernel

  test "runs one conversational turn end to end" do
    workflow =
      ChatAgentKernel.new(
        name: :chat_kernel,
        model: "test:model",
        system: "You are helpful",
        client: RunicAI.LLM.TestClient
      )
      |> Workflow.react_until_satisfied(%{user: "Hello"})

    assert %State{} = ChatAgentKernel.latest_state(workflow)
    assert %TurnResult{} = ChatAgentKernel.latest_turn_result(workflow)

    assert %ContinueDecision{action: :continue} =
             ChatAgentKernel.latest_continue_decision(workflow)

    assert ChatAgentKernel.latest_reply_text(workflow) =~ "I received: Hello"
  end

  test "carries state across turns in a multi-turn kernel workflow" do
    client = fn _model, %Prompt{messages: messages}, _opts ->
      last_user =
        messages
        |> Enum.filter(&(&1.role == :user))
        |> List.last()
        |> Map.get(:content)

      response =
        cond do
          String.contains?(last_user, "favorite color") ->
            RunicAI.LLM.TestClient.result("noted")

          String.contains?(last_user, "What color") and
              Enum.any?(messages, &String.contains?(&1.content, "vermilion")) ->
            RunicAI.LLM.TestClient.result("vermilion")

          true ->
            RunicAI.LLM.TestClient.result("unknown")
        end

      {:ok, response}
    end

    first_turn =
      ChatAgentKernel.new(
        name: :chat_kernel_first,
        model: "test:model",
        system: "You are concise",
        client: client
      )
      |> Workflow.react_until_satisfied(%{
        user: "My favorite color is vermilion. Reply only with noted."
      })

    first_state = ChatAgentKernel.latest_state(first_turn)
    assert ChatAgentKernel.latest_reply_text(first_turn) == "noted"

    second_turn =
      ChatAgentKernel.new(
        name: :chat_kernel_second,
        model: "test:model",
        client: client
      )
      |> Workflow.react_until_satisfied(%{
        state: first_state,
        user: "What color did I say was my favorite? Reply with one word."
      })

    second_state = ChatAgentKernel.latest_state(second_turn)

    assert second_state.conversation.turns == 2
    assert ChatAgentKernel.latest_reply_text(second_turn) == "vermilion"
  end

  test "interprets final answers and emits a stop decision" do
    workflow =
      ChatAgentKernel.new(
        name: :chat_kernel_final,
        model: "test:model",
        final_pattern: "DONE",
        client: fn _model, _prompt, _opts -> {:ok, RunicAI.LLM.TestClient.result("DONE")} end
      )
      |> Workflow.react_until_satisfied(%{user: "finish"})

    assert %TurnResult{kind: :final} = ChatAgentKernel.latest_turn_result(workflow)
    assert %ContinueDecision{action: :stop} = ChatAgentKernel.latest_continue_decision(workflow)
  end
end
