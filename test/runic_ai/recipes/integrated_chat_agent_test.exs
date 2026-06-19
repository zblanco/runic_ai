defmodule RunicAI.Recipes.IntegratedChatAgentTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias RunicAI.Prompt
  alias RunicAI.Recipes.IntegratedAgentKernel
  alias RunicAI.Recipes.IntegratedChatAgent

  test "kernel ignores non-ready productions without calling lane processor" do
    parent = self()

    workflow =
      IntegratedAgentKernel.new(
        default_agent_id: "chat",
        processor: fn bundle ->
          send(parent, {:processor_called, bundle})
          []
        end
      )
      |> Workflow.react_until_satisfied(%{kind: :stop})

    assert RunicAI.Recipes.IntegratedAgentKernel.runtime_state(workflow).ready_queue == []
    refute_receive {:processor_called, _bundle}
  end

  test "keeps chat state inside the workflow across repeated signals" do
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

    workflow =
      IntegratedChatAgent.new(
        default_agent_id: "chat",
        model: "test:model",
        system: "You are concise",
        client: client
      )
      |> Workflow.react_until_satisfied(%{
        user: "My favorite color is vermilion. Reply only with noted."
      })

    assert IntegratedChatAgent.latest_reply_text(workflow, "chat") == "noted"

    workflow =
      Workflow.react_until_satisfied(
        workflow,
        %{user: "What color did I say was my favorite? Reply with one word."}
      )

    session = IntegratedChatAgent.session(workflow, "chat")

    assert IntegratedChatAgent.latest_reply_text(workflow, "chat") == "vermilion"
    assert session.status == :idle
    assert session.agent_state.conversation.turns == 2
  end

  test "isolates multiple agent lanes in the same workflow" do
    client = fn _model, %Prompt{messages: messages}, _opts ->
      last_user =
        messages
        |> Enum.filter(&(&1.role == :user))
        |> List.last()
        |> Map.get(:content)

      {:ok, RunicAI.LLM.TestClient.result("echo: #{last_user}")}
    end

    workflow =
      IntegratedChatAgent.new(
        model: "test:model",
        client: client,
        agents: [
          [id: "alpha"],
          [id: "beta"]
        ]
      )
      |> Workflow.react_until_satisfied(%{agent_id: "alpha", user: "hello alpha"})
      |> Workflow.react_until_satisfied(%{agent_id: "beta", user: "hello beta"})

    alpha = IntegratedChatAgent.session(workflow, "alpha")
    beta = IntegratedChatAgent.session(workflow, "beta")

    assert List.last(alpha.agent_state.conversation.messages).content == "echo: hello alpha"
    assert List.last(beta.agent_state.conversation.messages).content == "echo: hello beta"
    assert alpha.agent_state.conversation.turns == 1
    assert beta.agent_state.conversation.turns == 1
  end
end
