defmodule RunicAI.Terminal.EventTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.Error
  alias RunicAI.ReviewRequest
  alias RunicAI.RLM.Episode
  alias RunicAI.Terminal.Event
  alias RunicAI.Trace.Event, as: TraceEvent

  test "constructs JSON-safe terminal events without raw payloads" do
    raw = %{secret: "kept in memory"}

    event =
      Event.new!(:status,
        agent: :standard,
        status: :running,
        title: "Started",
        data: %{phase: :start, at: DateTime.utc_now()},
        raw: raw
      )

    json = Event.to_json_map(event)

    assert json.kind == :status
    assert json.status == :running
    assert json.data["phase"] == "start"
    refute Map.has_key?(json, :raw)
  end

  test "constructs JSON-safe terminal events with tuple-keyed nested data" do
    event =
      Event.new!(:rlm_node,
        agent: :assistant,
        phase: :node_completed,
        status: :ok,
        title: "Tuple keyed payload",
        data: %{
          usage: %{
            {252_900_930, 3_074_849_482} => %{tokens: 42}
          }
        }
      )

    assert event.data["usage"]["{252900930, 3074849482}"]["tokens"] == 42

    json = Event.to_json_map(event)

    assert json.data["usage"]["{252900930, 3074849482}"]["tokens"] == 42
  end

  test "normalizes coding trace events to tool events" do
    trace =
      TraceEvent.new!(:coding_tool_call,
        output: %{name: "read_file", arguments: %{path: "lib/demo.ex"}},
        metadata: %{tool_name: "read_file"}
      )

    event = Event.from_trace_event(trace, session_id: "session-1")

    assert event.session_id == "session-1"
    assert event.kind == :tool
    assert event.phase == :call
    assert event.title == "Tool call: read_file"
  end

  test "normalizes review outputs to HITL events" do
    request =
      ReviewRequest.new!(:destructive_patch,
        resume_key: "review-1",
        details: %{reason: "delete file", path: "lib/old.ex"}
      )

    [event] = Event.from_output(%{latest_review_request: request}, session_id: "session-1")

    assert event.kind == :hitl
    assert event.status == :review
    assert event.data["resume_key"] == "review-1"
  end

  test "normalizes RLM result artifacts" do
    proposal =
      WorkflowProposal.new!(
        "Explain Demo",
        [
          ProposalNode.new!("inspect", :tool, params: %{tool: "find_files"}),
          ProposalNode.new!("answer", :reducer, params: %{reducer: "report"})
        ],
        edges: [%{from: "inspect", to: "answer"}],
        stop_conditions: ["answer returned"]
      )

    scorecard =
      WorkflowScorecard.new!(
        objective_status: :objective_satisfied,
        changed_files: ["lib/demo.ex"]
      )

    events =
      Event.from_rlm_result(%{
        proposal: proposal,
        validation_report: WorkflowValidationReport.accept(),
        objective_scorecard: scorecard
      })

    assert Enum.any?(events, &(&1.phase == :proposed))
    assert Enum.any?(events, &(&1.phase == :validated))
    assert Enum.any?(events, &(&1.phase == :scorecard and &1.status == :ok))
  end

  test "normalizes coding RLM final output as a chat-visible assistant message" do
    episode =
      Episode.new!(:satisfied, "Final repo summary for the conversation pane.",
        id: "episode:answer",
        parent_node_id: "answer",
        artifacts: ["Final repo summary for the conversation pane."]
      )

    events =
      Event.from_rlm_result(
        %{
          context: %{episodes: [episode]},
          objective_scorecard: WorkflowScorecard.new!(objective_status: :objective_satisfied)
        },
        session_id: "session:rlm",
        run_id: "run:rlm"
      )

    assert %Event{kind: :message, phase: :assistant, status: :ok, data: data} =
             Enum.find(events, &(&1.kind == :message))

    assert data["run_id"] == "run:rlm"
    assert data["role"] == "assistant"
    assert data["message_kind"] == "workflow_output"
    assert data["content"] == "Final repo summary for the conversation pane."
  end

  test "normalizes scorecard-only coding RLM completion as a visible assistant message" do
    events =
      Event.from_rlm_result(
        %{
          objective_scorecard:
            WorkflowScorecard.new!(
              objective_status: :objective_satisfied,
              changed_files: ["lib/demo.ex"],
              residual_risks: []
            )
        },
        session_id: "session:rlm",
        run_id: "run:rlm"
      )

    assert %Event{kind: :message, phase: :assistant, status: :ok, data: data} =
             Enum.find(events, &(&1.kind == :message))

    assert data["message_kind"] == "workflow_output"
    assert data["content"] =~ "RLM completed."
    assert data["content"] =~ "Objective status: objective_satisfied"
    assert data["content"] =~ "- lib/demo.ex"
  end

  test "normalizes assistant artifact outcomes on final chat messages" do
    events =
      Event.from_rlm_result(
        %{
          output_text: "# Report",
          artifacts: [%{path: ".docs/report.md"}],
          objective_scorecard: WorkflowScorecard.new!(objective_status: :objective_satisfied)
        },
        agent: :assistant,
        session_id: "session:assistant",
        run_id: "run:assistant"
      )

    assert %Event{kind: :message, data: data} = Enum.find(events, &(&1.kind == :message))
    assert data["artifact_paths"] == [".docs/report.md"]
    assert data["artifact_outcome"]["status"] == "artifact_written"
    assert data["artifact_outcome"]["paths"] == [".docs/report.md"]
  end

  test "normalizes assistant artifact-not-written outcomes on final chat messages" do
    events =
      Event.from_rlm_result(
        %{
          output_text: "Prepared the answer in chat because the artifact was not written.",
          artifacts: [],
          artifact_outcome: %{
            status: "artifact_not_written",
            reason: "repair_answer_only",
            path: ".docs/report.md"
          },
          objective_scorecard: WorkflowScorecard.new!(objective_status: :objective_satisfied)
        },
        agent: :assistant,
        session_id: "session:assistant",
        run_id: "run:assistant"
      )

    assert %Event{kind: :message, data: data} = Enum.find(events, &(&1.kind == :message))
    assert data["artifact_paths"] == []
    assert data["artifact_outcome"]["status"] == "artifact_not_written"
    assert data["artifact_outcome"]["reason"] == "repair_answer_only"
    assert data["artifact_outcome"]["path"] == ".docs/report.md"
  end

  test "extracts artifact-not-written outcomes from normalized errors" do
    error =
      Error.validation("artifact write denied by review",
        details: %{
          artifact_outcome: %{
            status: "artifact_not_written",
            reason: "denied",
            path: ".docs/report.md",
            suggested_paths: [".docs/report.md"]
          }
        }
      )

    assert %{
             status: "artifact_not_written",
             reason: "denied",
             path: ".docs/report.md",
             suggested_paths: [".docs/report.md"]
           } = Event.artifact_outcome_from_error(error)
  end

  test "normalizes structured coding RLM final output as markdown content" do
    episode =
      Episode.new!(:satisfied, %{files: [%{path: "README.md", content: "# Demo\n\nhello"}]},
        id: "episode:answer",
        parent_node_id: "answer",
        artifacts: [%{files: [%{path: "README.md", content: "# Demo\n\nhello"}]}]
      )

    events =
      Event.from_rlm_result(%{context: %{episodes: [episode]}},
        session_id: "session:rlm",
        run_id: "run:rlm"
      )

    assert %Event{kind: :message, data: data} = Enum.find(events, &(&1.kind == :message))

    assert data["content"] =~ "## File output"
    assert data["content"] =~ "```markdown\n# Demo\n\nhello\n```"
    refute data["content"] =~ "%{"
    refute data["content"] =~ "\\n"
  end

  test "normalizes assistant blocked final output as a visible draft message" do
    events =
      Event.from_rlm_result(
        %{
          output: %{text: "Useful answer that still needs provenance formatting."},
          objective_scorecard: %{
            objective_status: :objective_incomplete,
            residual_risks: ["source/provenance coverage was required but not present"]
          }
        },
        agent: :assistant,
        session_id: "session:assistant",
        run_id: "run:assistant"
      )

    assert %Event{kind: :message, agent: :assistant, status: :blocked, data: data} =
             Enum.find(events, &(&1.kind == :message))

    assert data["message_kind"] == "workflow_output"
    assert data["content"] == "Useful answer that still needs provenance formatting."
    assert data["blocked?"] == true
    assert data["blocking_reason"] =~ "source/provenance"
  end

  test "blocked RLM final output carries structured contract and progress evidence" do
    contract =
      ObjectiveContract.infer!(
        "Build an Elixir field service dispatch proof of concept with tests"
      )

    events =
      Event.from_rlm_result(
        %{
          status: :blocked,
          output: "RLM runtime budget exhausted during active workflow execution",
          objective_scorecard:
            WorkflowScorecard.new!(
              objective_status: :blocked,
              residual_risks: ["implementation node timed out before verification"],
              acceptance_results: [
                %{id: "source-present", status: :fail, message: "missing source"}
              ]
            ),
          context: %{
            objective_contract: contract,
            runtime_timeout: %{elapsed_ms: 65_000, max_runtime_ms: 65_000, remaining_ms: 0},
            last_event: %{
              stage: :child_agent_progress,
              status: :running,
              data: %{node_id: "implement_project", child_id: "codex-child-1"}
            },
            repair_needs: [
              %{id: "runtime-budget-exhausted", target: "implement_project"}
            ]
          }
        },
        session_id: "session:rlm-blocked",
        run_id: "run:rlm-blocked"
      )

    assert %Event{kind: :message, status: :blocked, data: data} =
             Enum.find(events, &(&1.kind == :message))

    assert data["objective_contract"]["metadata"]["domain"] == "field_service"

    assert data["repair_needs"] == [
             %{"id" => "runtime-budget-exhausted", "target" => "implement_project"}
           ]

    assert data["blocked_evidence"]["current_node"] == "implement_project"
    assert data["blocked_evidence"]["current_child"] == "codex-child-1"
    assert data["blocked_evidence"]["elapsed_ms"] == 65_000
    assert [%{"id" => "source-present"}] = data["blocked_evidence"]["unsatisfied_acceptance"]
    assert Enum.any?(data["next_actions"], &String.contains?(&1, "implement_project"))

    assert %Event{kind: :summary, phase: :scorecard, status: :blocked, data: scorecard_data} =
             Enum.find(events, &(&1.kind == :summary and &1.phase == :scorecard))

    assert scorecard_data["blocked_evidence"]["current_node"] == "implement_project"
  end

  test "normalizes Runic runnable lifecycle stages into JSON-safe trace events" do
    event =
      Event.from_rlm_stage(
        %{
          run_id: "run-1",
          stage: :node_completed,
          status: :ok,
          data: %{
            node: "assistant_node_3_map",
            input: "%{record: 1}",
            output: "%{text: \"ok\"}",
            runnable: %{
              id: 42,
              node: "assistant_node_3_map",
              component_id: "map",
              component_type: :record_map,
              policy: %{max_retries: 1, executor_opts: %{max_concurrency: 1}}
            }
          }
        },
        agent: :assistant
      )

    json = Event.to_json_map(event)

    assert json.session_id == "run-1"
    assert json.kind == :rlm_node
    assert json.phase == :node_completed
    assert json.data["data"]["runnable"]["id"] == 42
    assert json.data["data"]["runnable"]["component_id"] == "map"
    assert json.data["data"]["runnable"]["component_type"] == "record_map"
    assert json.data["data"]["runnable"]["policy"]["executor_opts"]["max_concurrency"] == 1
  end

  test "normalizes LLM stream stages into chunk and message events" do
    chunk =
      Event.from_rlm_stage(
        %{
          run_id: "run:stream",
          stage: :llm_stream_chunk,
          status: :running,
          data: %{
            run_id: "run:stream",
            agent: :assistant,
            message_id: "stream:assistant:run:stream:final",
            content: "Hello ",
            chunk: "Hello ",
            sequence: 1,
            stream_complete: false
          }
        },
        agent: :assistant
      )

    assert chunk.kind == :chunk
    assert chunk.phase == :assistant_chunk
    assert chunk.status == :running
    assert chunk.detail == "Hello "
    assert chunk.data["message_id"] == "stream:assistant:run:stream:final"

    completed =
      Event.from_stream_stage(%{
        run_id: "run:stream",
        stage: :llm_stream_completed,
        status: :ok,
        data: %{
          run_id: "run:stream",
          agent: :assistant,
          message_id: "stream:assistant:run:stream:final",
          content: "Hello world",
          stream_complete: true
        }
      })

    assert completed.kind == :message
    assert completed.phase == :assistant
    assert completed.status == :ok
    assert completed.detail == "Hello world"
    assert completed.data["stream_complete"] == true
  end
end
