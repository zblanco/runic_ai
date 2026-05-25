defmodule RunicAI.Persistence.SQLiteTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.RLM.ObjectiveLoop
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.Export
  alias RunicAI.Persistence.Inspection
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.AgentMessageChunk
  alias RunicAI.Persistence.Schemas.AgentSession
  alias RunicAI.Persistence.Schemas.ReviewRequest
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.Scorecard
  alias RunicAI.Persistence.Schemas.TerminalEvent
  alias RunicAI.Persistence.Schemas.ToolCall
  alias RunicAI.Persistence.Schemas.WorkflowRun
  alias RunicAI.ReviewDecision
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

  test "concurrent terminal events retry sequence collisions", %{store: store} do
    results =
      1..20
      |> Task.async_stream(
        fn index ->
          SQLite.record_terminal_event(store, %{
            id: "event:concurrent:#{index}",
            session_id: "session:concurrent",
            run_id: "run:concurrent",
            agent: :rlm,
            kind: :rlm_node,
            phase: :node_started,
            status: :running,
            title: "Concurrent event #{index}",
            data_json: %{index: index},
            at: DateTime.utc_now()
          })
        end,
        max_concurrency: 20,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %TerminalEvent{}}, &1))

    events = Queries.run_timeline(store, "run:concurrent")
    sequences = Enum.map(events, & &1.sequence)

    assert length(events) == 20
    assert Enum.sort(sequences) == Enum.to_list(1..20)
  end

  test "stream chunks project into one accumulating message row", %{store: store} do
    at = ~U[2026-05-03 12:09:00Z]

    assert {:ok, %TerminalEvent{sequence: 1}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:stream:1",
               session_id: "session:stream",
               run_id: "run:stream",
               agent: :assistant,
               kind: :chunk,
               phase: :assistant_chunk,
               status: :running,
               title: "Assistant stream chunk",
               detail: "Hello ",
               data_json: %{
                 run_id: "run:stream",
                 stream_id: "assistant:run:stream:final",
                 message_id: "stream:assistant:run:stream:final",
                 role: "assistant",
                 message_kind: "stream",
                 channel: "content",
                 chunk: "Hello ",
                 content: "Hello ",
                 sequence: 1,
                 source_step: "generate_turn"
               },
               at: at
             })

    assert {:ok, %TerminalEvent{sequence: 2}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:stream:2",
               session_id: "session:stream",
               run_id: "run:stream",
               agent: :assistant,
               kind: :chunk,
               phase: :assistant_chunk,
               status: :running,
               title: "Assistant stream chunk",
               detail: "world",
               data_json: %{
                 run_id: "run:stream",
                 stream_id: "assistant:run:stream:final",
                 message_id: "stream:assistant:run:stream:final",
                 role: "assistant",
                 message_kind: "stream",
                 channel: "content",
                 chunk: "world",
                 content: "world",
                 sequence: 2,
                 source_step: "generate_turn"
               },
               at: DateTime.add(at, 1, :second)
             })

    assert [
             %AgentMessage{
               id: "stream:assistant:run:stream:final",
               role: "assistant",
               message_kind: "stream",
               content: "Hello world",
               stream_complete: false,
               presentation_group_id: "run:stream"
             }
           ] = Queries.messages_for_run(store, "run:stream")

    chunks =
      SQLite.with_repo(store, fn ->
        store.repo.all(AgentMessageChunk)
      end)
      |> Enum.sort_by(& &1.sequence)

    assert Enum.map(chunks, & &1.content) == ["Hello ", "world"]
    assert Enum.map(chunks, & &1.chunk_kind) == ["content", "content"]

    assert {:ok, %TerminalEvent{sequence: 3}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:stream:3",
               session_id: "session:stream",
               run_id: "run:stream",
               agent: :assistant,
               kind: :message,
               phase: :assistant,
               status: :ok,
               title: "Assistant response",
               detail: "Hello world",
               data_json: %{
                 run_id: "run:stream",
                 message_id: "stream:assistant:run:stream:final",
                 role: "assistant",
                 message_kind: "stream",
                 content: "Hello world",
                 stream_complete: true,
                 source_step: "generate_turn"
               },
               at: DateTime.add(at, 2, :second)
             })

    assert [
             %AgentMessage{
               id: "stream:assistant:run:stream:final",
               content: "Hello world",
               stream_complete: true
             }
           ] = Queries.messages_for_run(store, "run:stream")
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

  test "objective-loop terminal events are queryable as durable loop state", %{store: store} do
    at = ~U[2026-05-24 12:00:00Z]

    assert {:ok, %TerminalEvent{}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:objective-loop:1",
               session_id: "session:objective-loop",
               run_id: "run:objective-loop",
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :review,
               title: "Objective budget approval required",
               detail: "status: needs_budget_approval, action: request_budget_approval",
               data_json: %{
                 run_id: "run:objective-loop",
                 objective_iteration_count: 2,
                 objective_session: %{
                   id: "run:objective-loop",
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   iteration_count: 2,
                   max_iterations: 2,
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   },
                   decision: %{
                     action: :request_budget_approval,
                     status: :needs_budget_approval
                   }
                 },
                 objective_decision: %{
                   action: :request_budget_approval,
                   status: :needs_budget_approval
                 },
                 open_tasks: [
                   %{id: "compile", title: "mix compile still fails", status: :open}
                 ],
                 completed_tasks: [],
                 budget_requests: [
                   %{reason: "repair budget exhausted before objective satisfaction"}
                 ]
               },
               at: at
             })

    assert [%TerminalEvent{phase: "objective_loop"}] =
             Queries.objective_loop_events(store, "run:objective-loop")

    assert %{
             action: "request_budget_approval",
             budget_requests: [
               %{"reason" => "repair budget exhausted before objective satisfaction"}
             ],
             iteration_count: 2,
             latest_error: %{
               "kind" => "timeout",
               "message" => "RLM runtime budget exhausted"
             },
             latest_error_kind: "timeout",
             latest_error_message: "RLM runtime budget exhausted",
             max_iterations: 2,
             objective: "Build OpsLogic",
             open_tasks: [%{"id" => "compile"}],
             status: "needs_budget_approval",
             title: "Objective budget approval required"
           } = Queries.latest_objective_loop_state(store, "run:objective-loop")

    assert {:ok, %TerminalEvent{}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:objective-loop:auto-resume-limit",
               session_id: "session:objective-loop",
               run_id: "run:objective-loop",
               agent: :rlm,
               kind: :status,
               phase: :objective_loop_resume,
               status: :blocked,
               title: "Objective auto-resume limit reached",
               detail: "objective still needs budget approval after 1 automatic resumes",
               data_json: %{
                 run_id: "run:objective-loop",
                 objective_session_id: "run:objective-loop",
                 objective_iteration_count: 2,
                 objective_session: %{
                   id: "run:objective-loop",
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   iteration_count: 2,
                   max_iterations: 2,
                   decision: %{action: :request_budget_approval}
                 },
                 objective_session_state: %{
                   id: "run:objective-loop",
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   created_at: at,
                   updated_at: at,
                   max_iterations: 2,
                   iterations: [],
                   progress_log: [],
                   completed_tasks: [],
                   open_tasks: [%{id: "compile", title: "mix compile still fails"}],
                   review_requests: [],
                   budget_requests: [%{id: "budget:run:objective-loop:2", status: :pending}],
                   metadata: %{}
                 },
                 objective_decision: %{action: :request_budget_approval},
                 open_tasks: [%{id: "compile", title: "mix compile still fails"}],
                 budget_requests: [%{id: "budget:run:objective-loop:2", status: :pending}],
                 resume_kind: :budget,
                 resume_key: "budget:run:objective-loop:2",
                 max_objective_auto_resumes: 1
               },
               at: DateTime.add(at, 5, :second)
             })

    assert [_, %TerminalEvent{phase: "objective_loop_resume"}] =
             Queries.objective_loop_events(store, "run:objective-loop")

    assert %{
             action: "request_budget_approval",
             budget_requests: [%{"id" => "budget:run:objective-loop:2"}],
             objective: "Build OpsLogic",
             status: "needs_budget_approval",
             title: "Objective auto-resume limit reached"
           } = Queries.latest_objective_loop_state(store, "run:objective-loop")

    assert objective_session = Queries.latest_objective_session(store, "run:objective-loop")
    assert objective_session.status == :needs_budget_approval
    assert [%{"id" => "compile"}] = objective_session.open_tasks

    assert Enum.any?(Queries.review_requests(store, "run:objective-loop"), fn review ->
             review.id == "budget:run:objective-loop:2" and
               review.kind == "objective_budget_approval" and
               review.status == "pending" and
               review.resume_key == "budget:run:objective-loop:2"
           end)
  end

  test "objective-loop progress events are reloadable durable loop state", %{store: store} do
    at = ~U[2026-05-24 12:03:00Z]

    assert {:ok, %TerminalEvent{}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:objective-progress:1",
               session_id: "session:objective-progress",
               run_id: "run:objective-progress",
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop_progress,
               status: :review,
               title: "Objective iteration errored",
               detail: "status: needs_budget_approval, action: request_budget_approval",
               data_json: %{
                 stage: :objective_loop,
                 event: :iteration_error,
                 status: :needs_budget_approval,
                 action: :request_budget_approval,
                 objective_session_id: "run:objective-progress",
                 objective: "Build OpsLogic",
                 current_iteration: 1,
                 iteration_count: 1,
                 max_iterations: 3,
                 objective_session: %{
                   id: "run:objective-progress",
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   iteration_count: 1,
                   max_iterations: 3,
                   latest_error: %{kind: :timeout, message: "RLM runtime budget exhausted"}
                 },
                 objective_session_state: %{
                   id: "run:objective-progress",
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   created_at: at,
                   updated_at: at,
                   max_iterations: 3,
                   iterations: [%{iteration: 1, status: :needs_budget_approval}],
                   progress_log: [],
                   completed_tasks: [],
                   open_tasks: [%{id: "implementation", title: "Implement OpsLogic"}],
                   review_requests: [],
                   budget_requests: [
                     %{
                       id: "budget:run:objective-progress:1",
                       resume_key: "budget:run:objective-progress:1",
                       status: :pending,
                       reason: "runtime budget exhausted during active workflow execution"
                     }
                   ],
                   latest_error: %{kind: :timeout, message: "RLM runtime budget exhausted"},
                   metadata: %{}
                 },
                 open_tasks: [%{id: "implementation", title: "Implement OpsLogic"}],
                 budget_requests: [
                   %{
                     id: "budget:run:objective-progress:1",
                     resume_key: "budget:run:objective-progress:1",
                     status: :pending,
                     reason: "runtime budget exhausted during active workflow execution"
                   }
                 ]
               },
               at: at
             })

    assert [%TerminalEvent{phase: "objective_loop_progress"}] =
             Queries.objective_loop_events(store, "run:objective-progress")

    assert %{
             action: "request_budget_approval",
             latest_error_kind: "timeout",
             latest_error_message: "RLM runtime budget exhausted",
             pending_budget_requests: [%{"id" => "budget:run:objective-progress:1"}],
             status: "needs_budget_approval",
             title: "Objective iteration errored"
           } = Queries.latest_objective_loop_state(store, "run:objective-progress")

    assert objective_session = Queries.latest_objective_session(store, "run:objective-progress")
    assert objective_session.status == :needs_budget_approval
    assert [%{"id" => "implementation"}] = objective_session.open_tasks

    assert [
             %ReviewRequest{
               id: "budget:run:objective-progress:1",
               kind: "objective_budget_approval",
               status: "pending",
               resume_key: "budget:run:objective-progress:1"
             }
           ] = Queries.review_requests(store, "run:objective-progress")
  end

  test "objective-loop approval requests project from serialized session state", %{store: store} do
    at = ~U[2026-05-24 12:04:00Z]

    assert {:ok, %TerminalEvent{}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:objective-state-review",
               session_id: "session:objective-state-review",
               run_id: "run:objective-state-review",
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :review,
               title: "Objective review approval required",
               detail: "status: needs_review_approval",
               data_json: %{
                 run_id: "run:objective-state-review",
                 objective_session: %{
                   id: "run:objective-state-review",
                   objective: "Plan OpsLogic",
                   status: :needs_review_approval,
                   decision: %{action: :request_review_approval}
                 },
                 objective_session_state: %{
                   id: "run:objective-state-review",
                   objective: "Plan OpsLogic",
                   status: :needs_review_approval,
                   created_at: at,
                   updated_at: at,
                   max_iterations: 2,
                   iterations: [%{iteration: 1, status: :needs_review_approval}],
                   progress_log: [],
                   completed_tasks: [],
                   open_tasks: [],
                   review_requests: [
                     %{
                       kind: :objective_plan_approval,
                       resume_key: "review:state-only:plan",
                       checkpoint: :plan_review,
                       status: :pending
                     }
                   ],
                   budget_requests: [],
                   metadata: %{}
                 }
               },
               at: at
             })

    assert {:ok, %TerminalEvent{}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:objective-state-budget",
               session_id: "session:objective-state-budget",
               run_id: "run:objective-state-budget",
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop_progress,
               status: :review,
               title: "Objective budget approval required",
               detail: "status: needs_budget_approval",
               data_json: %{
                 stage: :objective_loop,
                 event: :iteration_completed,
                 objective_session_id: "run:objective-state-budget",
                 objective_session_state: %{
                   id: "run:objective-state-budget",
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   created_at: at,
                   updated_at: at,
                   max_iterations: 1,
                   iterations: [%{iteration: 1, status: :needs_budget_approval}],
                   progress_log: [],
                   completed_tasks: [],
                   open_tasks: [%{id: "implementation", title: "Implement OpsLogic"}],
                   review_requests: [],
                   budget_requests: [
                     %{
                       id: "budget:state-only:1",
                       resume_key: "budget:state-only:1",
                       reason: "runtime budget exhausted during active workflow execution",
                       status: :pending
                     }
                   ],
                   metadata: %{}
                 }
               },
               at: DateTime.add(at, 1, :second)
             })

    assert %{
             action: "request_review_approval",
             pending_review_requests: [%{"resume_key" => "review:state-only:plan"}],
             status: "needs_review_approval"
           } = Queries.latest_objective_loop_state(store, "run:objective-state-review")

    assert [
             %ReviewRequest{
               id: "review:state-only:plan",
               kind: "objective_plan_approval",
               status: "pending",
               resume_key: "review:state-only:plan"
             }
           ] = Queries.review_requests(store, "run:objective-state-review")

    assert %{
             action: "request_budget_approval",
             pending_budget_requests: [%{"id" => "budget:state-only:1"}],
             status: "needs_budget_approval"
           } = Queries.latest_objective_loop_state(store, "run:objective-state-budget")

    assert [
             %ReviewRequest{
               id: "budget:state-only:1",
               kind: "objective_budget_approval",
               status: "pending",
               resume_key: "budget:state-only:1"
             }
           ] = Queries.review_requests(store, "run:objective-state-budget")
  end

  test "objective-loop review requests are queryable as durable loop state", %{store: store} do
    at = ~U[2026-05-24 12:05:00Z]

    assert {:ok, %TerminalEvent{}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:objective-loop:review",
               session_id: "session:objective-review",
               run_id: "run:objective-review",
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :review,
               title: "Objective review approval required",
               detail: "status: needs_review_approval, action: request_review_approval",
               data_json: %{
                 run_id: "run:objective-review",
                 objective_iteration_count: 1,
                 objective_session: %{
                   id: "run:objective-review",
                   objective: "Plan OpsLogic",
                   status: :needs_review_approval,
                   iteration_count: 1,
                   max_iterations: 2,
                   latest_review_request: %{
                     kind: :objective_plan_approval,
                     resume_key: "review:opslogic:plan",
                     checkpoint: :plan_review
                   },
                   decision: %{
                     action: :request_review_approval,
                     status: :needs_review_approval
                   }
                 },
                 objective_decision: %{
                   action: :request_review_approval,
                   status: :needs_review_approval
                 },
                 objective_session_state: %{
                   id: "run:objective-review",
                   objective: "Plan OpsLogic",
                   status: :needs_review_approval,
                   created_at: at,
                   updated_at: at,
                   max_iterations: 2,
                   iterations: [
                     %{
                       iteration: 1,
                       status: :needs_review_approval,
                       review_request: %{
                         kind: :objective_plan_approval,
                         resume_key: "review:opslogic:plan",
                         checkpoint: :plan_review
                       }
                     }
                   ],
                   progress_log: [],
                   completed_tasks: [],
                   open_tasks: [],
                   review_requests: [
                     %{
                       kind: :objective_plan_approval,
                       resume_key: "review:opslogic:plan",
                       checkpoint: :plan_review
                     }
                   ],
                   budget_requests: [],
                   metadata: %{plan_path: "tmp/ops_logic/PLAN.md"}
                 },
                 review_requests: [
                   %{
                     kind: :objective_plan_approval,
                     resume_key: "review:opslogic:plan",
                     checkpoint: :plan_review
                   }
                 ]
               },
               at: at
             })

    assert %{
             action: "request_review_approval",
             latest_review_request: %{"resume_key" => "review:opslogic:plan"},
             review_requests: [%{"checkpoint" => "plan_review"}],
             status: "needs_review_approval",
             title: "Objective review approval required"
           } = Queries.latest_objective_loop_state(store, "run:objective-review")

    assert objective_session = Queries.latest_objective_session(store, "run:objective-review")
    assert objective_session.status == :needs_review_approval
    assert objective_session.metadata == %{"plan_path" => "tmp/ops_logic/PLAN.md"}
    assert [%{"resume_key" => "review:opslogic:plan"}] = objective_session.review_requests
    assert [%{"iteration" => 1}] = objective_session.iterations

    runner = fn _workspace, objective, opts ->
      assert Keyword.fetch!(opts, :objective_iteration) == 2
      assert objective =~ "Continue the objective after operator approval"

      {:ok,
       %{
         objective_scorecard: %{objective_status: :objective_satisfied},
         context: %{changed_files: ["tmp/ops_logic/mix.exs"]}
       }}
    end

    assert {:ok, resumed} =
             ObjectiveLoop.resume_after_review(
               :workspace,
               objective_session,
               ReviewDecision.new!("review:opslogic:plan", :approved),
               runner: runner
             )

    assert resumed.decision.action == :complete
    assert resumed.session.status == :objective_satisfied
    assert length(resumed.session.iterations) == 2
  end

  test "objective-loop resolved request summaries update durable review rows", %{store: store} do
    at = ~U[2026-05-24 12:10:00Z]

    assert {:ok, %TerminalEvent{}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:objective-loop:budget-pending",
               session_id: "session:objective-budget",
               run_id: "run:objective-budget",
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :review,
               title: "Objective budget approval required",
               detail: "status: needs_budget_approval",
               data_json: %{
                 run_id: "run:objective-budget",
                 objective_session: %{
                   id: "run:objective-budget",
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   decision: %{action: :request_budget_approval}
                 },
                 objective_decision: %{action: :request_budget_approval},
                 budget_requests: [
                   %{
                     id: "budget:run:objective-budget:1",
                     resume_key: "budget:run:objective-budget:1",
                     reason: "repair budget exhausted",
                     status: :pending
                   }
                 ]
               },
               at: at
             })

    assert [%ReviewRequest{id: "budget:run:objective-budget:1", status: "pending"}] =
             Queries.review_requests(store, "run:objective-budget")

    assert {:ok, %TerminalEvent{}} =
             SQLite.record_terminal_event(store, %{
               id: "terminal:objective-loop:budget-complete",
               session_id: "session:objective-budget",
               run_id: "run:objective-budget",
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :ok,
               title: "Objective satisfied",
               detail: "status: objective_satisfied",
               data_json: %{
                 run_id: "run:objective-budget",
                 objective_session: %{
                   id: "run:objective-budget",
                   objective: "Build OpsLogic",
                   status: :objective_satisfied,
                   decision: %{action: :complete}
                 },
                 objective_decision: %{action: :complete},
                 budget_requests: [
                   %{
                     id: "budget:run:objective-budget:1",
                     resume_key: "budget:run:objective-budget:1",
                     reason: "repair budget exhausted",
                     status: :approved,
                     decision: %{resume_key: "budget:run:objective-budget:1", status: :approved}
                   }
                 ]
               },
               at: DateTime.add(at, 5, :second)
             })

    assert [
             %ReviewRequest{
               id: "budget:run:objective-budget:1",
               status: "approved",
               decision_json: %{"status" => "approved"}
             }
           ] = Queries.review_requests(store, "run:objective-budget")
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

  test "assistant blocked final result events project best output as non-transient draft", %{
    store: store
  } do
    final_event =
      %{
        output: %{text: "Best repaired comparison draft."},
        objective_scorecard: %{
          objective_status: :objective_incomplete,
          residual_risks: ["source/provenance coverage was required but not present"]
        }
      }
      |> Event.from_rlm_result(
        agent: :assistant,
        session_id: "session:assistant-blocked",
        run_id: "run:assistant-blocked"
      )
      |> Enum.find(&(&1.kind == :message))

    assert {:ok, %TerminalEvent{run_id: "run:assistant-blocked", sequence: 1}} =
             SQLite.record_terminal_event(store, final_event)

    assert [
             %AgentMessage{
               role: "assistant",
               message_kind: "workflow_output",
               content: "Best repaired comparison draft.",
               transient: false
             }
           ] = Queries.messages_for_run(store, "run:assistant-blocked")
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
