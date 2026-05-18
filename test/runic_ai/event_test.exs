defmodule RunicAI.EventTest do
  use ExUnit.Case, async: true

  alias RunicAI.Event
  alias RunicAI.Terminal.Event, as: TerminalEvent

  test "constructs JSON-safe core events with top-level run identity" do
    event =
      Event.new!(:status,
        session_id: "session:core",
        run_id: "run:core",
        agent: :assistant,
        phase: :session,
        status: :running,
        title: "Core run started",
        data: %{run_id: "run:core", nested: %{phase: :started}}
      )

    json = Event.to_json_map(event)

    assert json.run_id == "run:core"
    assert json.kind == :status
    assert json.data["nested"]["phase"] == "started"
  end

  test "constructs JSON-safe core events with tuple-keyed nested data" do
    event =
      Event.new!(:rlm_node,
        session_id: "session:tuple",
        run_id: "run:tuple",
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

  test "normalizes LLM stream stages into core chunk and completion events" do
    chunk =
      Event.from_stream_stage(%{
        run_id: "run:stream",
        stage: :llm_stream_chunk,
        status: :running,
        data: %{
          run_id: "run:stream",
          message_id: "stream:assistant:run:stream:final",
          content: "Hello ",
          chunk: "Hello ",
          sequence: 1,
          stream_complete: false
        }
      })

    assert %Event{
             kind: :chunk,
             phase: :assistant_chunk,
             run_id: "run:stream",
             status: :running,
             data: %{"message_id" => "stream:assistant:run:stream:final"}
           } = chunk

    completed =
      Event.from_stream_stage(%{
        run_id: "run:stream",
        stage: :llm_stream_completed,
        status: :ok,
        data: %{
          run_id: "run:stream",
          message_id: "stream:assistant:run:stream:final",
          content: "Hello world",
          stream_complete: true
        }
      })

    assert %Event{kind: :message, phase: :assistant, status: :ok} = completed
    assert completed.data["stream_complete"] == true
  end

  test "builds workflow presentation effects without depending on terminal events" do
    analysis =
      Event.workflow_effect!(:analysis,
        session_id: "session:workflow",
        run_id: "run:workflow",
        agent: :assistant,
        source_step: :synthesize,
        workflow_node: "synthesize_response",
        content: "Working notes"
      )

    assert analysis.kind == :message
    assert analysis.data["message_kind"] == "analysis"
    assert analysis.data["transient"] == true
    assert analysis.data["presentation_group_id"] == "run:workflow"
    assert analysis.data["workflow_node"] == "synthesize_response"

    final =
      Event.workflow_effect!(:final,
        session_id: "session:workflow",
        run_id: "run:workflow",
        agent: :assistant,
        content: "Final answer"
      )

    assert final.kind == :message
    assert final.data["message_kind"] == "final"
    assert final.data["transient"] == false
    assert final.data["content"] == "Final answer"
  end

  test "terminal events adapt core events for terminal clients" do
    core =
      Event.workflow_effect!(:progress,
        session_id: "session:terminal",
        run_id: "run:terminal",
        agent: :assistant,
        detail: "node started"
      )

    terminal = TerminalEvent.from_core(core)

    assert %TerminalEvent{kind: :rlm_node, agent: :assistant, data: data} = terminal
    assert data["run_id"] == "run:terminal"
    assert TerminalEvent.to_core(terminal).run_id == "run:terminal"
  end

  test "terminal events prefer the core run identity over stale data identities" do
    core =
      Event.new!(:rlm_node,
        session_id: "session:web",
        run_id: "run:web",
        agent: :assistant,
        phase: :node_started,
        status: :running,
        title: "Node started",
        data: %{"run_id" => "session:web", run_id: "session:web"}
      )

    terminal = TerminalEvent.from_core(core)

    assert terminal.data["run_id"] == "run:web"
    refute Map.get(terminal.data, "run_id") == "session:web"
    assert TerminalEvent.to_core(terminal).run_id == "run:web"
  end
end
