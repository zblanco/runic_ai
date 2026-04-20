defmodule RunicAI.Steps.ContextStepsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Context.Graph
  alias RunicAI.Retrieval.Document
  alias RunicAI.Retrieval.Result
  alias RunicAI.Steps.AssembleContextBundle
  alias RunicAI.Steps.CompactContext
  alias RunicAI.Steps.EvaluateContextPressure
  alias RunicAI.Steps.InferFocus
  alias RunicAI.Steps.IngestContextTurn
  alias RunicAI.Steps.RecallMemory
  alias RunicAI.Steps.RetrieveContext
  alias RunicAI.Steps.WriteMemory

  test "ingests conversation history, compacts old context, and assembles a summary-backed bundle" do
    state =
      State.new!(system: "You are helpful")
      |> State.append_messages!([
        {:user, "We need to debug the deployment pipeline for the Phoenix app."},
        {:assistant, "Noted. I will look at the deployment path."},
        {:user, "The failure happens after assets compile but before release packaging."},
        {:assistant, "That suggests the packaging or artifact upload step."}
      ])

    turn_request =
      TurnRequest.new!(state,
        input_message: "What details are still most relevant?",
        model: "test:model"
      )

    ingested_turn_request = IngestContextTurn.ingest!(turn_request)
    focus = InferFocus.infer!(ingested_turn_request, nil)
    memory_result = RecallMemory.recall!(ingested_turn_request, focus)
    retrieval_result = Result.empty(text: focus.goal)

    decision =
      EvaluateContextPressure.evaluate!(
        ingested_turn_request,
        focus,
        memory_result,
        retrieval_result,
        window_policy: [
          max_input_tokens: 120,
          reserve_output_tokens: 20,
          soft_pressure_tokens: 55,
          hard_pressure_tokens: 75,
          fresh_tail_messages: 2,
          fresh_tail_tokens: 35
        ]
      )

    compacted_turn_request =
      CompactContext.compact!(
        ingested_turn_request,
        focus,
        decision,
        policy: [
          leaf_target_tokens: 16,
          condensed_target_tokens: 12,
          max_depth_per_pass: 1
        ]
      )

    bundle =
      AssembleContextBundle.assemble!(
        compacted_turn_request,
        focus,
        memory_result,
        retrieval_result,
        window_policy: [fresh_tail_messages: 2, fresh_tail_tokens: 35]
      )

    assert decision.action == :compact

    assert Enum.any?(
             Graph.list_nodes_by_kind(compacted_turn_request.state.context.graph, :summary)
           )

    assert Enum.any?(bundle.messages, &String.contains?(&1.content, "[CONTEXT SUMMARY]"))
  end

  test "writes semantic memory and recalls it on a later turn" do
    state =
      State.new!(system: "You are helpful")
      |> State.append_messages!([
        {:user, "My favorite color is vermilion."},
        {:assistant, "Got it."}
      ])

    turn_result = TurnResult.reply!("Got it.")
    state_with_memory = WriteMemory.write!(state, turn_result)

    turn_request =
      TurnRequest.new!(state_with_memory,
        input_message: "What color did I say was my favorite?",
        model: "test:model"
      )

    focus = InferFocus.infer!(turn_request, nil)
    memory_result = RecallMemory.recall!(turn_request, focus)

    assert Enum.any?(memory_result.entries, &(&1.kind == :semantic))
    assert Enum.any?(memory_result.entries, &String.contains?(&1.content, "favorite color"))
  end

  test "retrieves local documents through the normalized retrieval step" do
    state = State.new!(system: "You are helpful")

    turn_request =
      TurnRequest.new!(state, input_message: "Explain the rollout plan", model: "test:model")

    focus = InferFocus.infer!(turn_request, "rollout plan")

    documents = [
      Document.new!(id: "one", content: "The rollout plan uses blue-green deployment."),
      Document.new!(id: "two", content: "The authentication spec covers session refresh.")
    ]

    result = RetrieveContext.retrieve!(turn_request, focus, provider: documents, top_k: 1)

    assert [document] = result.documents
    assert document.id == "one"
  end
end
