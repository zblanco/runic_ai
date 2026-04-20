defmodule RunicAI.Recipes.SummaryBackedChatAgentTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias RunicAI.Agent.State
  alias RunicAI.Context.Bundle
  alias RunicAI.Recipes.SummaryBackedChatAgent

  test "runs a summary-backed turn and exposes the assembled bundle" do
    state =
      State.new!(system: "You are concise")
      |> State.append_messages!([
        {:user, "We are debugging a flaky deployment pipeline in production."},
        {:assistant, "Understood."},
        {:user, "The build passes until the artifact packaging stage."},
        {:assistant, "That points at packaging or upload."}
      ])

    client = fn _model, %RunicAI.Prompt{messages: messages}, _opts ->
      response =
        if Enum.any?(messages, &String.contains?(&1.content, "[CONTEXT SUMMARY]")) do
          RunicAI.LLM.TestClient.result("summary-seen")
        else
          RunicAI.LLM.TestClient.result("no-summary")
        end

      {:ok, response}
    end

    workflow =
      SummaryBackedChatAgent.new(
        model: "test:model",
        state: state,
        client: client,
        window_policy: [
          max_input_tokens: 120,
          reserve_output_tokens: 20,
          soft_pressure_tokens: 40,
          hard_pressure_tokens: 55,
          fresh_tail_messages: 2,
          fresh_tail_tokens: 35
        ],
        compaction_policy: [
          leaf_target_tokens: 16,
          condensed_target_tokens: 12,
          max_depth_per_pass: 1
        ]
      )
      |> Workflow.react_until_satisfied(%{user: "What matters most right now?"})

    assert SummaryBackedChatAgent.latest_reply_text(workflow) == "summary-seen"
    assert %Bundle{} = SummaryBackedChatAgent.latest_bundle(workflow)
    assert SummaryBackedChatAgent.latest_pressure_decision(workflow).action == :compact
    assert SummaryBackedChatAgent.latest_state(workflow).context != nil
  end
end
