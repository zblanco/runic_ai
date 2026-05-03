defmodule RunicAI.Terminal.EventTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.ReviewRequest
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
end
