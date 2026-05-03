defmodule RunicAI.Persistence.SQLiteTest do
  use ExUnit.Case, async: true

  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.Export
  alias RunicAI.Persistence.Inspection
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.AgentSession
  alias RunicAI.Persistence.Schemas.ReviewRequest
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.Scorecard
  alias RunicAI.Persistence.Schemas.TerminalEvent
  alias RunicAI.Persistence.Schemas.ToolCall
  alias RunicAI.Persistence.Schemas.WorkflowRun

  setup do
    {:ok, store} = SQLite.open(":memory:")
    on_exit(fn -> SQLite.close(store) end)
    %{store: store}
  end

  test "migrates all core durability tables", %{store: store} do
    assert {:ok, 1} = SQLite.schema_version(store)

    tables =
      SQLite.with_repo(store, fn ->
        store.repo.query!(
          """
          SELECT name
          FROM sqlite_master
          WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
          ORDER BY name
          """,
          []
        )
      end)
      |> Map.fetch!(:rows)
      |> List.flatten()

    assert "agent_sessions" in tables
    assert "workflow_runs" in tables
    assert "workflow_events" in tables
    assert "workflow_facts" in tables
    assert "terminal_events" in tables
    assert "terminal_events_fts" in tables
  end

  test "dynamic repo stores are isolated" do
    {:ok, first} = SQLite.open(":memory:")
    {:ok, second} = SQLite.open(":memory:")

    on_exit(fn ->
      SQLite.close(first)
      SQLite.close(second)
    end)

    insert_session(first, "session:first")
    insert_session(second, "session:second")

    assert ["session:first"] = session_ids(first)
    assert ["session:second"] = session_ids(second)
  end

  test "records and searches terminal events", %{store: store} do
    {:ok, %TerminalEvent{} = event} =
      SQLite.record_terminal_event(store, %{
        id: "event:1",
        run_id: "run:1",
        sequence: 1,
        agent: :assistant,
        kind: :summary,
        phase: :final,
        status: :ok,
        title: "Final answer",
        detail: "The workflow mentioned salience and progress.",
        data_json: %{score: %{salience: 0.9}},
        at: DateTime.utc_now()
      })

    assert event.id == "event:1"
    assert [%TerminalEvent{id: "event:1"}] = Queries.run_timeline(store, "run:1")
    assert [%TerminalEvent{id: "event:1"}] = Queries.search_events(store, "salience")
  end

  test "schema changesets reject invalid statuses and missing identity fields" do
    invalid =
      AgentSession.changeset(%AgentSession{}, %{
        agent_kind: :standard,
        status: :nonsense,
        started_at: DateTime.utc_now(),
        metadata_json: %{}
      })

    refute invalid.valid?
    assert %{status: ["is invalid"]} = errors_on(invalid)

    missing =
      WorkflowRun.changeset(%WorkflowRun{}, %{
        id: "run:missing",
        status: :running,
        metadata_json: %{},
        error_json: %{}
      })

    refute missing.valid?

    assert %{workflow_key: ["can't be blank"], workflow_id_blob: ["can't be blank"]} =
             errors_on(missing)
  end

  test "query helpers cover timelines, latest runs, tool calls, scorecards, and FTS", %{
    store: store
  } do
    insert_workflow_run(store, "run:old", "workflow:key", ~U[2026-05-03 10:00:00Z])
    insert_workflow_run(store, "run:new", "workflow:key", ~U[2026-05-03 11:00:00Z])

    record_event(store, "event:timeline:1", "run:new", 1, "First", "mentions source-cue-1")
    record_event(store, "event:timeline:2", "run:new", 2, "Second", "done")

    SQLite.with_repo(store, fn ->
      %ToolCall{}
      |> ToolCall.changeset(%{
        id: "tool:1",
        workflow_run_id: "run:new",
        tool_name: "read_file",
        status: :completed,
        args_json: %{path: "README.md"},
        result_json: %{preview: "ok"},
        error_json: %{},
        requested_at: ~U[2026-05-03 11:00:01Z]
      })
      |> store.repo.insert!()

      %Scorecard{}
      |> Scorecard.changeset(%{
        run_id: "run:new",
        objective_status: :objective_satisfied,
        scorecard_json: %{salience: 0.9},
        created_at: ~U[2026-05-03 11:00:02Z]
      })
      |> store.repo.insert!()
    end)

    assert %WorkflowRun{id: "run:new"} = Queries.latest_run_for_workflow(store, "workflow:key")

    assert ["event:timeline:1", "event:timeline:2"] =
             Enum.map(Queries.run_timeline(store, "run:new"), & &1.id)

    assert [%ToolCall{tool_name: "read_file"}] = Queries.tool_calls(store, "run:new")

    assert [%Scorecard{objective_status: "objective_satisfied"}] =
             Queries.scorecards_for_run(store, "run:new")

    assert [%TerminalEvent{id: "event:timeline:1"}] = Queries.search_events(store, "source-cue-1")
  end

  test "terminal events project first-class harness rows and export JSONL", %{store: store} do
    at = ~U[2026-05-03 12:00:00Z]

    assert {:ok, %TerminalEvent{sequence: 1}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:start",
               session_id: "session:projection",
               agent: :standard,
               kind: :status,
               phase: :session,
               status: :running,
               title: "Standard agent started",
               detail: "/tmp/demo",
               data_json: %{
                 cwd: "/tmp/demo",
                 objective: "Inspect persistence",
                 model: "test:model"
               },
               at: at
             })

    assert {:ok, %TerminalEvent{sequence: 2}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:message",
               session_id: "session:projection",
               agent: :standard,
               kind: :message,
               phase: :assistant,
               status: :ok,
               title: "Assistant response",
               detail: "Final answer cites source-cue-2",
               data_json: %{reply_text: "Final answer cites source-cue-2"},
               at: DateTime.add(at, 1)
             })

    assert {:ok, %TerminalEvent{sequence: 3}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:tool",
               session_id: "session:projection",
               agent: :standard,
               kind: :tool,
               phase: :call,
               status: :running,
               title: "Tool call: read_file",
               detail: "README.md",
               data_json: %{
                 output: %{name: "read_file", arguments: %{path: "README.md"}}
               },
               at: DateTime.add(at, 2)
             })

    assert {:ok, %TerminalEvent{sequence: 4}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:review",
               session_id: "session:projection",
               agent: :standard,
               kind: :hitl,
               phase: :review,
               status: :review,
               title: "Review required",
               detail: "write .docs/report.md",
               data_json: %{
                 kind: :write,
                 checkpoint: "before_write",
                 resume_key: "resume:1",
                 details: %{path: ".docs/report.md"}
               },
               at: DateTime.add(at, 3)
             })

    assert {:ok, %TerminalEvent{sequence: 5}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:summary",
               session_id: "session:projection",
               agent: :assistant,
               kind: :summary,
               phase: :scorecard,
               status: :ok,
               title: "Assistant RLM objective objective_satisfied",
               detail: "changed=1 risks=0",
               data_json: %{
                 scorecard: %{objective_status: :objective_satisfied, salience: 0.8},
                 artifacts: [%{path: ".docs/report.md", kind: :summary}],
                 compiled: %{graph_summary: %{nodes: [%{id: "write"}]}}
               },
               at: DateTime.add(at, 4)
             })

    assert {:ok, %TerminalEvent{sequence: 6}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:repair",
               session_id: "session:projection",
               agent: :assistant,
               kind: :repair,
               phase: :repair,
               status: :ok,
               title: "Assistant RLM repairs: 1",
               detail: "fixed missing artifact path",
               data_json: %{
                 repair_history: [
                   %{
                     strategy: :runtime_diagnostic_repair,
                     reason: "missing path",
                     status: :repaired
                   }
                 ]
               },
               at: DateTime.add(at, 5)
             })

    rows =
      SQLite.with_repo(store, fn ->
        %{
          messages: store.repo.all(AgentMessage),
          tools: store.repo.all(ToolCall),
          reviews: store.repo.all(ReviewRequest),
          scorecards: store.repo.all(Scorecard),
          artifacts: store.repo.all(RunArtifact),
          sessions: store.repo.all(AgentSession)
        }
      end)

    assert [%AgentSession{id: "session:projection"}] = rows.sessions
    assert Enum.any?(rows.messages, &(&1.content =~ "source-cue-2"))
    assert [%ToolCall{tool_name: "read_file"}] = rows.tools
    assert [%ReviewRequest{resume_key: "resume:1"}] = rows.reviews
    assert [%Scorecard{objective_status: "objective_satisfied"}] = rows.scorecards

    assert Enum.any?(
             rows.artifacts,
             &(&1.artifact_kind == "summary" and &1.path == ".docs/report.md")
           )

    assert Enum.any?(rows.artifacts, &(&1.artifact_kind == "workflow_graph"))

    assert %{objective_status: "objective_satisfied"} =
             Inspection.scorecard_status(store, "session:projection")

    exported = Export.terminal_jsonl(store, "session:projection")
    assert exported |> String.split("\n", trim: true) |> length() == 6
    assert exported =~ "source-cue-2"
  end

  defp insert_session(store, id) do
    SQLite.with_repo(store, fn ->
      %AgentSession{}
      |> AgentSession.changeset(%{
        id: id,
        agent_kind: :standard,
        status: :running,
        started_at: DateTime.utc_now(),
        metadata_json: %{}
      })
      |> store.repo.insert!()
    end)
  end

  defp insert_workflow_run(store, id, workflow_key, started_at) do
    SQLite.with_repo(store, fn ->
      %WorkflowRun{}
      |> WorkflowRun.changeset(%{
        id: id,
        workflow_key: workflow_key,
        workflow_name: workflow_key,
        workflow_id_blob: :erlang.term_to_binary(id),
        status: :completed,
        metadata_json: %{},
        error_json: %{},
        started_at: started_at
      })
      |> store.repo.insert!()
    end)
  end

  defp record_event(store, id, run_id, sequence, title, detail) do
    SQLite.record_terminal_event(store, %{
      id: id,
      run_id: run_id,
      sequence: sequence,
      agent: :assistant,
      kind: :summary,
      phase: :final,
      status: :ok,
      title: title,
      detail: detail,
      data_json: %{detail: detail},
      at: DateTime.utc_now()
    })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp session_ids(store) do
    SQLite.with_repo(store, fn ->
      store.repo.all(AgentSession)
    end)
    |> Enum.map(& &1.id)
  end
end
