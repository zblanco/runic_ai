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
  alias RunicAI.RLM.Episode
  alias RunicAI.Terminal.Event

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

  test "assistant direct response stages project first-class message rows", %{store: store} do
    at = ~U[2026-05-03 12:10:00Z]

    assert {:ok, %TerminalEvent{sequence: 1}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:direct-response",
               session_id: "assistant:direct",
               run_id: "assistant:direct",
               agent: :assistant,
               kind: :rlm_plan,
               phase: :direct_response_completed,
               status: :ok,
               title: "Assistant RLM Direct response completed ok",
               detail: "preview only",
               data_json: %{
                 stage: :direct_response_completed,
                 status: :ok,
                 data: %{
                   reply_text: "Frogs hum softly beside the moonlit reeds.",
                   output: %{text_preview: "Frogs hum softly beside the moonlit reeds."}
                 }
               },
               at: at
             })

    rows =
      SQLite.with_repo(store, fn ->
        %{
          messages: store.repo.all(AgentMessage),
          sessions: store.repo.all(AgentSession),
          runs: store.repo.all(WorkflowRun)
        }
      end)

    assert [
             %AgentMessage{
               role: "assistant",
               message_kind: "direct_response",
               content: "Frogs hum softly beside the moonlit reeds."
             }
           ] = rows.messages

    assert [%AgentSession{status: "running"}] = rows.sessions
    assert [%WorkflowRun{status: "running"}] = rows.runs
    assert [%AgentMessage{}] = Queries.messages_for_run(store, "assistant:direct")
  end

  test "assistant error events project concise chat messages", %{store: store} do
    at = ~U[2026-05-03 12:12:00Z]

    assert {:ok, %TerminalEvent{sequence: 1}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:assistant-error",
               session_id: "assistant:error",
               run_id: "assistant:error",
               agent: :assistant,
               kind: :error,
               phase: :run,
               status: :error,
               title: "Assistant RLM agent failed",
               detail:
                 "protocol Jason.Encoder not implemented for RunicAI.Error (a struct)\n\nIf you own the struct, derive Jason.Encoder.",
               data_json: %{
                 error: %{
                   kind: :unexpected,
                   message:
                     "protocol Jason.Encoder not implemented for RunicAI.Error (a struct)\n\nIf you own the struct, derive Jason.Encoder."
                 }
               },
               at: at
             })

    assert [
             %AgentMessage{
               role: "assistant",
               message_kind: "error",
               content:
                 "Error: protocol Jason.Encoder not implemented for RunicAI.Error (a struct)"
             }
           ] = Queries.messages_for_run(store, "assistant:error")
  end

  test "assistant workflow llm_leaf completions project first-class message rows", %{store: store} do
    at = ~U[2026-05-03 12:15:00Z]

    assert {:ok, %TerminalEvent{sequence: 1}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:workflow-output",
               session_id: "assistant:workflow",
               run_id: "assistant:workflow",
               agent: :assistant,
               kind: :rlm_node,
               phase: :node_completed,
               status: :ok,
               title: "Assistant RLM Node completed ok",
               detail: "synthesis complete",
               data_json: %{
                 stage: :node_completed,
                 status: :ok,
                 data: %{
                   runnable: %{
                     id: 123,
                     node: "assistant_node_1_synthesize_response",
                     component_id: "synthesize_response",
                     component_type: "llm_leaf"
                   },
                   output: %{count: 1, strategy: :llm_reduce},
                   policy_events: [
                     %{
                       result_fact: %{
                         value: %{
                           text:
                             "Workflow graphs compose durable, inspectable execution from named nodes and facts."
                         }
                       }
                     }
                   ]
                 }
               },
               at: at
             })

    assert [
             %AgentMessage{
               role: "assistant",
               message_kind: "workflow_output",
               content:
                 "Workflow graphs compose durable, inspectable execution from named nodes and facts.",
               transient: true
             }
           ] = Queries.messages_for_run(store, "assistant:workflow")
  end

  test "assistant completed workflow stage projects the final non-transient chat output", %{
    store: store
  } do
    at = ~U[2026-05-03 12:16:00Z]

    assert {:ok, %TerminalEvent{sequence: 1}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:workflow-intermediate-output",
               session_id: "assistant:workflow-final",
               run_id: "assistant:workflow-final",
               agent: :assistant,
               kind: :rlm_node,
               phase: :node_completed,
               status: :ok,
               title: "Assistant RLM Node completed ok",
               detail: "synthesis complete",
               data_json: %{
                 stage: :node_completed,
                 status: :ok,
                 data: %{
                   node_id: "synthesize",
                   type: "llm_leaf",
                   output: %{text: "Intermediate answer before scorecard repair."}
                 }
               },
               at: at
             })

    assert {:ok, %TerminalEvent{sequence: 2}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:workflow-final-output",
               session_id: "assistant:workflow-final",
               run_id: "assistant:workflow-final",
               agent: :assistant,
               kind: :rlm_plan,
               phase: :completed,
               status: :ok,
               title: "Assistant RLM Completed ok",
               detail: "completed",
               data_json: %{
                 stage: :completed,
                 status: :ok,
                 data: %{
                   output_text: "Final repaired answer with provenance-backed summary."
                 }
               },
               at: DateTime.add(at, 1, :second)
             })

    assert [
             %AgentMessage{
               content: "Intermediate answer before scorecard repair.",
               transient: true
             },
             %AgentMessage{
               content: "Final repaired answer with provenance-backed summary.",
               transient: false
             }
           ] = Queries.messages_for_run(store, "assistant:workflow-final")
  end

  test "coding RLM final result events project non-transient workflow output messages", %{
    store: store
  } do
    episode =
      Episode.new!(:satisfied, "Repo A handles UI, Repo B handles data, Repo C handles docs.",
        id: "episode:answer",
        parent_node_id: "answer",
        artifacts: ["Repo A handles UI, Repo B handles data, Repo C handles docs."]
      )

    final_event =
      %{context: %{episodes: [episode]}}
      |> Event.from_rlm_result(session_id: "session:rlm-chat", run_id: "run:rlm-chat")
      |> Enum.find(&(&1.kind == :message))

    assert {:ok, %TerminalEvent{run_id: "run:rlm-chat", sequence: 1}} =
             SQLite.record_terminal_event(store, final_event)

    assert [
             %AgentMessage{
               role: "assistant",
               message_kind: "workflow_output",
               content: "Repo A handles UI, Repo B handles data, Repo C handles docs.",
               transient: false,
               presentation_group_id: "run:rlm-chat"
             }
           ] = Queries.messages_for_run(store, "run:rlm-chat")
  end

  test "assistant review stages project nested HITL review requests", %{store: store} do
    at = ~U[2026-05-03 12:20:00Z]

    review_data = %{
      id: "review:artifact:1",
      kind: :assistant_artifact_write,
      checkpoint: :pre_write,
      resume_key: "review:artifact:1",
      options: [:approve, :reject, :cancel],
      details: %{path: ".docs/report.md", write_policy: :docs_only},
      metadata: %{safe?: true}
    }

    assert {:ok, %TerminalEvent{sequence: 1}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:assistant-review-requested",
               session_id: "assistant:review",
               run_id: "assistant:review",
               agent: :assistant,
               kind: :hitl,
               phase: :review_requested,
               status: :review,
               title: "Assistant RLM Review requested review",
               detail: "write .docs/report.md",
               data_json: %{stage: :review_requested, status: :review, data: review_data},
               at: at
             })

    assert {:ok, %TerminalEvent{sequence: 2}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:assistant-review-completed",
               session_id: "assistant:review",
               run_id: "assistant:review",
               agent: :assistant,
               kind: :hitl,
               phase: :review_completed,
               status: :ok,
               title: "Assistant RLM Review completed ok",
               detail: "approved",
               data_json: %{
                 stage: :review_completed,
                 status: :ok,
                 data: Map.put(review_data, :decision, %{status: :approved})
               },
               at: DateTime.add(at, 1)
             })

    rows = SQLite.with_repo(store, fn -> store.repo.all(ReviewRequest) end)

    assert [
             %ReviewRequest{
               id: "review:artifact:1",
               kind: "assistant_artifact_write",
               checkpoint: "pre_write",
               resume_key: "review:artifact:1",
               status: "approved"
             }
           ] = rows
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
