defmodule RunicAI.WorkbenchTest do
  use ExUnit.Case, async: false

  alias RunicAI.Event
  alias RunicAI.Coding.TraceEvent
  alias RunicAI.Workbench
  alias RunicAI.Persistence.SQLite
  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.Event, as: TerminalEvent

  setup do
    SQLite.migrate!(Workbench.store!())
    :ok
  end

  test "records terminal events and hydrates a durable session snapshot" do
    session_id = unique_session_id("snapshot")

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("start"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :status,
               phase: :session,
               status: :running,
               title: "Workbench run queued",
               detail: "Inspect the workbench",
               data_json: %{
                 run_id: session_id,
                 cwd: File.cwd!(),
                 objective: "Inspect the workbench",
                 model: "test:model"
               },
               at: DateTime.utc_now()
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("message"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :message,
               phase: :assistant,
               status: :ok,
               title: "Assistant response",
               detail: "The workbench has **durable** chat.",
               data_json: %{reply_text: "The workbench has **durable** chat."},
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)
    assert snapshot.session.status == "running"
    assert snapshot.session.objective == "Inspect the workbench"
    assert [%{content: content}] = snapshot.messages
    assert content =~ "durable"
    assert snapshot.metrics.events == 2
  end

  test "session snapshot exposes objective contract and blocked next-action evidence" do
    session_id = unique_session_id("blocked-evidence")
    run_id = session_id <> ":run"

    contract = %{
      id: "objective-contract:test",
      metadata: %{domain: :field_service, evidence_required: ["source", "tests"]},
      requirements: [
        %{id: "implementation_artifacts", description: "Create source artifacts"}
      ]
    }

    blocked_evidence = %{
      current_node: "implement_project",
      current_child: "codex-child-1",
      elapsed_ms: 65_000,
      repair_needs: [%{id: "runtime-budget-exhausted", target: "implement_project"}],
      objective_contract: contract
    }

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("blocked-message"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :message,
               phase: :assistant,
               status: :blocked,
               title: "RLM final output",
               detail: "blocked",
               data_json: %{
                 run_id: run_id,
                 role: "assistant",
                 message_kind: "workflow_output",
                 content: "RLM blocked while implementing project.",
                 blocked?: true,
                 objective_contract: contract,
                 blocked_evidence: blocked_evidence,
                 next_actions: ["Repair implement_project"]
               },
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)
    assert snapshot.session.status == "blocked"
    assert snapshot.objective_contract["id"] == "objective-contract:test"
    assert snapshot.objective_contract["metadata"]["domain"] == "field_service"
    assert snapshot.blocked_evidence["current_node"] == "implement_project"
    assert snapshot.blocked_evidence["current_child"] == "codex-child-1"
    assert snapshot.progress_summary.current_node == "implement_project"
    assert snapshot.progress_summary.current_child == "codex-child-1"
    assert snapshot.progress_summary.elapsed_ms == 65_000
    assert snapshot.progress_summary.event_trail == "1 persisted events"
    assert [%{content_json: content_json}] = snapshot.messages

    assert content_json["blocked_evidence"]["repair_needs"] == [
             %{"id" => "runtime-budget-exhausted", "target" => "implement_project"}
           ]
  end

  test "session snapshot exposes objective contract from proposal-started events" do
    session_id = unique_session_id("proposal-contract")
    run_id = session_id <> ":run"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("proposal-contract"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :rlm_node,
               phase: :proposal_started,
               status: :running,
               title: "RLM proposal started",
               detail: "planning",
               data_json: %{
                 stage: :proposal_started,
                 status: :running,
                 data: %{
                   objective: "Create a report and verify it",
                   objective_contract: %{
                     id: "objective-contract:early",
                     objective: "Create a report and verify it",
                     requirements: [
                       %{id: "report_artifact", description: "Write the requested report"}
                     ],
                     metadata: %{source: :proposal_started, evidence_required: ["artifact"]}
                   }
                 }
               },
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)
    assert snapshot.objective_contract["id"] == "objective-contract:early"
    assert snapshot.objective_contract["metadata"]["source"] == "proposal_started"
    assert snapshot.objective_contract["metadata"]["evidence_required"] == ["artifact"]
    assert [%{"id" => "report_artifact"}] = snapshot.objective_contract["requirements"]
  end

  test "session snapshot exposes latest progress and runtime budget summary" do
    session_id = unique_session_id("progress-summary")
    run_id = session_id <> ":run"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("start"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :rlm_plan,
               phase: :proposal_started,
               status: :running,
               title: "RLM proposal started running",
               detail: "planning",
               data_json: %{
                 stage: :proposal_started,
                 status: :running,
                 data: %{max_runtime_ms: 90_000}
               },
               at: DateTime.utc_now()
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("budget"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :rlm_node,
               phase: :child_budget_selected,
               status: :running,
               title: "RLM child budget selected",
               detail: "budget",
               data_json: %{
                 stage: :child_budget_selected,
                 status: :running,
                 data: %{
                   node_id: "implement_project",
                   child_agent_id: "codex-child-2",
                   remaining_ms: 42_000,
                   selected_timeout_ms: 30_000,
                   max_runtime_ms: 90_000
                 }
               },
               at: DateTime.add(DateTime.utc_now(), 1)
             })

    assert snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.progress_summary.event_count == 2
    assert snapshot.progress_summary.event_trail == "2 persisted events"
    assert snapshot.progress_summary.current_node == "implement_project"
    assert snapshot.progress_summary.current_child == "codex-child-2"
    assert snapshot.progress_summary.remaining_ms == 42_000
    assert snapshot.progress_summary.selected_timeout_ms == 30_000
    assert snapshot.progress_summary.latest_event.title == "RLM child budget selected"
  end

  test "session snapshot exposes completion proof for completed sessions" do
    session_id = unique_session_id("completion-proof")
    run_id = session_id <> ":run"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("completion-proof"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :summary,
               phase: :final,
               status: :ok,
               title: "RLM final output",
               detail: "done",
               data_json: %{
                 run_id: run_id,
                 output_text: "Implemented dispatch proof with tests.",
                 scorecard: %{
                   objective_status: :objective_satisfied,
                   changed_files: [
                     "[depth limit]",
                     "lib/dispatch.ex",
                     "test/dispatch_test.exs",
                     "tmp/dispatch/mix.exs",
                     "tmp/dispatch/lib/dispatch.ex"
                   ],
                   acceptance_results: [
                     %{id: :mix_test, status: :pass, evidence: "mix test passed"}
                   ],
                   metadata: %{
                     objective_contract: %{
                       id: "objective-contract:test",
                       objective: "Implement dispatch proof",
                       requirements: [%{id: "implementation_artifacts"}],
                       metadata: %{evidence_required: ["source", "tests"]}
                     }
                   }
                 }
               },
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.session.status == "completed"
    assert snapshot.completion_proof.completed? == true
    assert snapshot.completion_proof.ready? == true
    assert snapshot.completion_proof.final_output? == true
    assert snapshot.completion_proof.scorecard_satisfied? == true
    assert snapshot.completion_proof.objective_contract? == true
    assert snapshot.completion_proof.changed_file_count == 2
    assert snapshot.completion_proof.all_changed_file_count == 4
    assert snapshot.completion_proof.scratch_changed_file_count == 2

    assert snapshot.completion_proof.changed_files == [
             "lib/dispatch.ex",
             "test/dispatch_test.exs"
           ]

    assert snapshot.completion_proof.delivered_changed_files == [
             "lib/dispatch.ex",
             "test/dispatch_test.exs"
           ]

    assert snapshot.completion_proof.scratch_changed_files == [
             "tmp/dispatch/lib/dispatch.ex",
             "tmp/dispatch/mix.exs"
           ]

    assert snapshot.completion_proof.missing == []
    assert "scorecard" in snapshot.completion_proof.proof_categories
    assert "changed_files" in snapshot.completion_proof.proof_categories
  end

  test "completion proof ignores unrelated nested path values" do
    session_id = unique_session_id("completion-proof-noisy-paths")
    run_id = session_id <> ":run"
    review_id = "review:noisy-paths:#{session_id}"

    seed_review_request(session_id, review_id)

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, review_id, %{
               "id" => review_id,
               "action" => "deny",
               "reason" => "do not write files"
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("completion-proof-noisy-final"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :summary,
               phase: :final,
               status: :ok,
               title: "RLM final output",
               detail: "blocked by denied review",
               data_json: %{
                 run_id: run_id,
                 output_text: "Stopped after the write request was denied.",
                 browser_capture: %{
                   elements: [
                     %{path: "html > body > main", text: "Workbench"},
                     %{path: "html > body > section.review", text: "Denied"}
                   ]
                 },
                 diagnostics: %{
                   selected_node: %{path: "workflow.nodes.implement_project"}
                 }
               },
               at: DateTime.add(DateTime.utc_now(), 1)
             })

    assert snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.completion_proof.completed? == true
    assert snapshot.completion_proof.ready? == true
    assert snapshot.completion_proof.denied_review? == true
    assert snapshot.completion_proof.final_output? == true
    assert snapshot.completion_proof.changed_files == []
    assert snapshot.completion_proof.artifact_paths == []
    assert snapshot.completion_proof.changed_file_count == 0
    assert snapshot.completion_proof.artifact_count == 0
    assert snapshot.completion_proof.proof_categories == ["final_output", "review_decision"]
  end

  test "completion proof is pending for active sessions" do
    session_id = unique_session_id("completion-proof-running")
    run_id = session_id <> ":run"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("completion-proof-running"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :rlm_node,
               phase: :proposal_started,
               status: :running,
               title: "RLM proposal started",
               detail: "planning",
               data_json: %{
                 stage: :proposal_started,
                 status: :running,
                 data: %{node_id: "create_project"}
               },
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.session.status == "running"
    assert snapshot.completion_proof.terminal? == false
    assert snapshot.completion_proof.completed? == false
    assert snapshot.completion_proof.ready? == false
    assert snapshot.completion_proof.missing == []
    assert snapshot.completion_proof.proof_categories == []
  end

  test "session snapshot summarizes child repair events for progress clarity" do
    session_id = unique_session_id("child-repair-summary")
    run_id = session_id <> ":run"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("child-patch-repair-started"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :rlm_node,
               phase: :child_patch_repair_started,
               status: :running,
               title: "RLM child patch repair started",
               detail: "repairing patch",
               data_json: %{
                 stage: :child_patch_repair_started,
                 status: :running,
                 data: %{
                   node_id: "child",
                   mode: :patch,
                   attempt: 1,
                   reason: :apply_patch_failed,
                   diagnostics: [
                     %{
                       code: :invalid_patch,
                       message: "invalid patch operation",
                       details: %{op: "make_file"}
                     }
                   ]
                 }
               },
               at: DateTime.utc_now()
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("child-patch-repair-completed"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :rlm_node,
               phase: :child_patch_repair_completed,
               status: :ok,
               title: "RLM child patch repair completed",
               detail: "patched",
               data_json: %{
                 stage: :child_patch_repair_completed,
                 status: :ok,
                 data: %{
                   node_id: "child",
                   mode: :patch,
                   attempt: 1,
                   changed_files: ["lib/malformed_patch_repair.ex"],
                   repaired?: true
                 }
               },
               at: DateTime.add(DateTime.utc_now(), 1)
             })

    assert snapshot = Workbench.session_snapshot(session_id)
    assert snapshot.metrics.child_repairs == 1

    assert [
             %{
               type: "patch",
               status: "repaired",
               title: "Malformed patch repaired",
               node_id: "child",
               attempt: 1,
               changed_files: ["lib/malformed_patch_repair.ex"],
               next_action: "Continue downstream verification or final objective proof."
             } = repair
           ] = snapshot.child_repairs

    assert to_string(repair.reason) == "apply_patch_failed"
    assert repair.detail =~ "Patch repair attempt 1 for child."
    assert repair.detail =~ "lib/malformed_patch_repair.ex"
    assert [diagnostic] = repair.diagnostics
    assert to_string(diagnostic["message"] || diagnostic[:message]) == "invalid patch operation"
  end

  test "session snapshot groups sandbox execution events from durable terminal events" do
    session_id = unique_session_id("sandbox-events")
    run_id = session_id <> ":run"

    trace_event =
      TraceEvent.sandbox(
        :coding_sandbox_completed,
        %{
          status: :pass,
          backend: :just_bash,
          isolation_level: :in_process_virtual,
          duration_ms: 12,
          exit_status: 0,
          output_bytes: 6,
          files_changed: [%{path: "out.txt", kind: :created}],
          artifacts: [%{ref: "sandbox://out.txt"}],
          diagnostics: [],
          metadata: %{
            session_id: "sandbox-session-1",
            vm_id: "vm-proof-1",
            workspace_mode: :copy_in,
            workspace_mount: "/workspace",
            security_boundary?: true
          }
        },
        status: :pass,
        input: %{
          sandbox: :local_code,
          runtime: :bash,
          network: :disabled,
          file_paths: ["seed.txt"]
        },
        metadata: %{
          sandbox?: true,
          sandbox: :local_code,
          runtime: :bash,
          network: :disabled,
          session_id: "sandbox-session-1"
        }
      )

    terminal_event =
      TerminalEvent.from_trace_event(trace_event,
        session_id: session_id,
        agent: :standard
      )

    terminal_event = %{terminal_event | data: Map.put(terminal_event.data, :run_id, run_id)}

    assert {:ok, _event} = Workbench.record_terminal_event(terminal_event)

    assert snapshot = Workbench.session_snapshot(session_id)
    assert snapshot.metrics.sandbox_executions == 1

    assert [
             %{
               backend: "just_bash",
               runtime: "bash",
               network: "disabled",
               isolation_level: "in_process_virtual",
               security_boundary?: true,
               session_id: "sandbox-session-1",
               vm_id: "vm-proof-1",
               workspace_mode: "copy_in",
               workspace_mount: "/workspace",
               copy_in_status: "request_files_uploaded",
               copy_back_status: "files_changed",
               files_changed: [%{"path" => "out.txt"}],
               proof: %{
                 backend: "just_bash",
                 sandbox: "local_code",
                 runtime: "bash",
                 network: "disabled",
                 isolation_level: "in_process_virtual",
                 security_boundary?: true,
                 session_id: "sandbox-session-1",
                 vm_id: "vm-proof-1",
                 workspace_mode: "copy_in",
                 workspace_mount: "/workspace",
                 request_file_count: 1,
                 files_changed_count: 1,
                 artifact_count: 1,
                 copy_in_status: "request_files_uploaded",
                 copy_back_status: "files_changed"
               }
             }
           ] = snapshot.sandbox_executions
  end

  test "session snapshot exposes objective-loop live progress fields" do
    session_id = unique_session_id("objective-progress-summary")
    run_id = session_id <> ":run"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("objective-progress"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop_progress,
               status: :running,
               title: "Objective iteration completed",
               detail: "status: running, action: continue, iteration: 2",
               data_json: %{
                 stage: :objective_loop,
                 event: :iteration_completed,
                 objective: "Build OpsLogic",
                 current_iteration: 2,
                 iteration_count: 2,
                 max_iterations: 3,
                 objective_session_id: run_id,
                 objective_session: %{
                   id: run_id,
                   objective: "Build OpsLogic",
                   status: :running,
                   decision: %{action: :continue}
                 },
                 run_deadline_ms: 9_999_999,
                 remaining_runtime_ms: 12_345,
                 max_runtime_ms: 60_000,
                 open_tasks: [%{id: "tests", title: "Add generated LiveView tests"}],
                 completed_tasks: [%{id: "plan", title: "Write implementation plan"}]
               },
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.progress_summary.latest_event.title == "Objective iteration completed"
    assert snapshot.progress_summary.objective == "Build OpsLogic"
    assert snapshot.progress_summary.objective_status == "running"
    assert snapshot.progress_summary.objective_action == "continue"
    assert snapshot.progress_summary.objective_iteration == 2
    assert snapshot.progress_summary.objective_max_iterations == 3
    assert snapshot.progress_summary.objective_open_task_count == 1
    assert snapshot.progress_summary.objective_completed_task_count == 1
    assert snapshot.progress_summary.remaining_ms == 12_345
    assert snapshot.progress_summary.run_deadline_ms == 9_999_999
    assert snapshot.progress_summary.max_runtime_ms == 60_000
    assert snapshot.objective_loop.status == "running"
    assert snapshot.objective_loop.action == "continue"
    assert snapshot.objective_loop.iteration_count == 2
    assert snapshot.objective_loop.max_iterations == 3
    assert [%{"id" => "tests"}] = snapshot.objective_loop.open_tasks
  end

  test "session snapshot exposes objective-loop latest error fields" do
    session_id = unique_session_id("objective-error-summary")
    run_id = session_id <> ":run"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("objective-error"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop_progress,
               status: :blocked,
               title: "Objective iteration error",
               detail: "status: needs_budget_approval, action: request_budget_approval",
               data_json: %{
                 stage: :objective_loop,
                 event: :iteration_error,
                 objective: "Build OpsLogic",
                 current_iteration: 1,
                 iteration_count: 0,
                 max_iterations: 3,
                 objective_session_id: run_id,
                 objective_session: %{
                   id: run_id,
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   },
                   latest_error_kind: :timeout,
                   latest_error_message: "RLM runtime budget exhausted",
                   decision: %{action: :request_budget_approval}
                 },
                 objective_session_state: %{
                   id: run_id,
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   }
                 }
               },
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.progress_summary.objective_status == "needs_budget_approval"
    assert snapshot.progress_summary.objective_action == "request_budget_approval"
    assert snapshot.progress_summary.objective_error_kind == "timeout"
    assert snapshot.progress_summary.objective_error_message == "RLM runtime budget exhausted"
  end

  test "session snapshot folds final objective-loop summary into progress facts" do
    session_id = unique_session_id("objective-final-summary")
    run_id = session_id <> ":run"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("objective-final"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :review,
               title: "Objective budget approval required",
               detail: "status: needs_budget_approval, action: request_budget_approval",
               data_json: %{
                 run_id: run_id,
                 objective_iteration_count: 1,
                 objective_session: %{
                   id: run_id,
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   iteration_count: 1,
                   max_iterations: 3,
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   },
                   decision: %{action: :request_budget_approval}
                 },
                 objective_session_state: %{
                   id: run_id,
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   iterations: [%{iteration: 1, status: :needs_budget_approval}],
                   max_iterations: 3,
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   }
                 },
                 objective_decision: %{action: :request_budget_approval}
               },
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.progress_summary.latest_event.title == "Objective budget approval required"
    assert snapshot.progress_summary.objective == "Build OpsLogic"
    assert snapshot.progress_summary.objective_status == "needs_budget_approval"
    assert snapshot.progress_summary.objective_action == "request_budget_approval"
    assert snapshot.progress_summary.objective_iteration == 1
    assert snapshot.progress_summary.objective_max_iterations == 3
    assert snapshot.progress_summary.objective_error_kind == "timeout"
    assert snapshot.progress_summary.objective_error_message == "RLM runtime budget exhausted"
  end

  test "session snapshot exposes objective auto-resume cap as objective-loop state" do
    session_id = unique_session_id("objective-auto-resume-cap")
    run_id = session_id <> ":run"
    now = DateTime.utc_now()

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("objective-cap"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :status,
               phase: :objective_loop_resume,
               status: :blocked,
               title: "Objective auto-resume limit reached",
               detail: "objective still needs budget approval after 1 automatic resumes",
               data_json: %{
                 run_id: run_id,
                 objective_session_id: run_id,
                 objective_iteration_count: 2,
                 objective_session: %{
                   id: run_id,
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   iteration_count: 2,
                   max_iterations: 2,
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   },
                   decision: %{action: :request_budget_approval}
                 },
                 objective_session_state: %{
                   id: run_id,
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   created_at: now,
                   updated_at: now,
                   max_iterations: 2,
                   iterations: [],
                   progress_log: [],
                   completed_tasks: [],
                   open_tasks: [%{id: "implementation", title: "Finish implementation"}],
                   review_requests: [],
                   budget_requests: [%{id: "budget:auto-resume-cap", status: :pending}],
                   metadata: %{}
                 },
                 objective_decision: %{action: :request_budget_approval},
                 open_tasks: [%{id: "implementation", title: "Finish implementation"}],
                 budget_requests: [%{id: "budget:auto-resume-cap", status: :pending}],
                 resume_kind: :budget,
                 resume_key: "budget:auto-resume-cap",
                 max_objective_auto_resumes: 1
               },
               at: now
             })

    assert snapshot = Workbench.session_snapshot(session_id)
    assert snapshot.objective_loop.title == "Objective auto-resume limit reached"
    assert snapshot.objective_loop.status == "needs_budget_approval"
    assert snapshot.objective_loop.action == "request_budget_approval"
    assert [%{"id" => "budget:auto-resume-cap"}] = snapshot.objective_loop.budget_requests
    assert [%{id: "budget:auto-resume-cap", status: "pending"}] = snapshot.review_requests
    assert snapshot.progress_summary.latest_event.title == "Objective auto-resume limit reached"
    assert snapshot.progress_summary.objective_status == "needs_budget_approval"
  end

  test "browser approval resumes an objective from an auto-resume cap review row" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_objective_loop_cap_budget_resume_run/3)
      |> Keyword.put(:max_runtime_ms, 3_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("objective-auto-resume-cap-approval")
    run_id = session_id <> ":run"
    budget_id = "budget:auto-resume-cap:approval"
    now = DateTime.utc_now()

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("objective-cap-approval"),
               session_id: session_id,
               run_id: run_id,
               agent: :rlm,
               kind: :status,
               phase: :objective_loop_resume,
               status: :blocked,
               title: "Objective auto-resume limit reached",
               detail: "objective still needs budget approval after 1 automatic resumes",
               data_json: %{
                 run_id: run_id,
                 objective_session_id: run_id,
                 objective_iteration_count: 2,
                 objective_session: %{
                   id: run_id,
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   iteration_count: 2,
                   max_iterations: 2,
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   },
                   decision: %{action: :request_budget_approval}
                 },
                 objective_session_state: %{
                   id: run_id,
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   created_at: now,
                   updated_at: now,
                   max_iterations: 2,
                   iterations: [
                     %{iteration: 1, status: :needs_budget_approval},
                     %{iteration: 2, status: :needs_budget_approval}
                   ],
                   progress_log: [],
                   completed_tasks: [%{id: "plan", title: "Plan OpsLogic"}],
                   open_tasks: [%{id: "implementation", title: "Finish implementation"}],
                   review_requests: [],
                   budget_requests: [
                     %{
                       id: budget_id,
                       resume_key: budget_id,
                       reason: "repair budget exhausted",
                       status: :pending
                     }
                   ],
                   metadata: %{}
                 },
                 objective_decision: %{action: :request_budget_approval},
                 open_tasks: [%{id: "implementation", title: "Finish implementation"}],
                 completed_tasks: [%{id: "plan", title: "Plan OpsLogic"}],
                 budget_requests: [
                   %{
                     id: budget_id,
                     resume_key: budget_id,
                     reason: "repair budget exhausted",
                     status: :pending
                   }
                 ],
                 resume_kind: :budget,
                 resume_key: budget_id,
                 max_objective_auto_resumes: 1
               },
               at: now
             })

    assert %{review_requests: [%{id: ^budget_id, status: "pending"}]} =
             Workbench.session_snapshot(session_id)

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, budget_id, %{
               "id" => budget_id,
               "action" => "approve",
               "additional_iterations" => "1"
             })

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)
        latest = Workbench.latest_objective_session(session_id)

        assert latest.status == :objective_satisfied
        assert length(latest.iterations) == 3
        assert latest.max_iterations == 3
        assert snapshot.objective_loop.status == "objective_satisfied"
        assert snapshot.objective_loop.action == "complete"
        assert snapshot.objective_loop.pending_budget_requests == []

        assert [%{"id" => ^budget_id, "status" => "approved"}] =
                 snapshot.objective_loop.budget_requests

        assert [%{id: ^budget_id, status: "approved"}] = snapshot.review_requests
      end,
      120
    )
  end

  test "browser budget approval resumes an objective from progress-only loop state" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_objective_loop_budget_run/3)
      |> Keyword.put(:max_runtime_ms, 3_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("objective-progress-budget-approval")
    run_id = session_id <> ":run"
    budget_id = "budget:#{run_id}:1"
    objective = "Implement OpsLogic code under ./tmp/ops_logic"
    now = DateTime.utc_now()
    before_deadline = System.monotonic_time(:millisecond) - 1

    budget_request = %{
      id: budget_id,
      resume_key: budget_id,
      kind: :objective_budget_approval,
      checkpoint: :budget_approval,
      reason: "runtime budget exhausted during active workflow execution",
      status: :pending
    }

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("objective-progress-budget-approval"),
               session_id: session_id,
               run_id: run_id,
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
                 objective_session_id: run_id,
                 objective: objective,
                 current_iteration: 1,
                 iteration_count: 1,
                 max_iterations: 1,
                 objective_session: %{
                   id: run_id,
                   objective: objective,
                   status: :needs_budget_approval,
                   iteration_count: 1,
                   max_iterations: 1,
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   },
                   decision: %{action: :request_budget_approval}
                 },
                 objective_session_state: %{
                   id: run_id,
                   objective: objective,
                   status: :needs_budget_approval,
                   created_at: now,
                   updated_at: now,
                   max_iterations: 1,
                   iterations: [%{iteration: 1, status: :needs_budget_approval}],
                   progress_log: [],
                   completed_tasks: [%{id: "plan", title: "Plan OpsLogic"}],
                   open_tasks: [%{id: "implementation", title: "Implement OpsLogic"}],
                   review_requests: [],
                   budget_requests: [budget_request],
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   },
                   metadata: %{
                     run_deadline_ms: before_deadline,
                     max_runtime_ms: 3_000
                   }
                 },
                 open_tasks: [%{id: "implementation", title: "Implement OpsLogic"}],
                 completed_tasks: [%{id: "plan", title: "Plan OpsLogic"}],
                 budget_requests: [budget_request]
               },
               at: now
             })

    assert %{review_requests: [%{id: ^budget_id, status: "pending"}]} =
             Workbench.session_snapshot(session_id)

    assert latest = Workbench.latest_objective_session(session_id)
    assert latest.status == :needs_budget_approval
    assert length(latest.iterations) == 1
    assert latest.max_iterations == 1

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, budget_id, %{
               "id" => budget_id,
               "action" => "approve",
               "additional_iterations" => "2",
               "additional_runtime_ms" => "1500"
             })

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)
        latest = Workbench.latest_objective_session(session_id)

        assert latest.status == :objective_satisfied
        assert length(latest.iterations) == 2
        assert latest.max_iterations == 3
        assert latest.metadata["run_deadline_ms"] > before_deadline
        assert latest.metadata["max_runtime_ms"] == 3_000
        assert snapshot.objective_loop.status == "objective_satisfied"
        assert snapshot.objective_loop.action == "complete"
        assert snapshot.objective_loop.pending_budget_requests == []

        assert [%{"id" => ^budget_id, "status" => "approved"}] =
                 snapshot.objective_loop.budget_requests

        assert Enum.any?(snapshot.events, fn event ->
                 event.run_id == run_id and event.phase == "objective_loop_resume"
               end)

        assert [%{id: ^budget_id, status: "approved"}] = snapshot.review_requests
      end,
      120
    )
  end

  test "session snapshot exposes durable RLM objective-loop state" do
    session_id = unique_session_id("objective-loop")

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("objective-loop"),
               session_id: session_id,
               run_id: session_id,
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :review,
               title: "Objective budget approval required",
               detail: "status: needs_budget_approval",
               data_json: %{
                 run_id: session_id,
                 objective_iteration_count: 2,
                 objective_session: %{
                   id: session_id,
                   objective: "Build OpsLogic",
                   status: :needs_budget_approval,
                   iteration_count: 2,
                   max_iterations: 2,
                   latest_error: %{
                     kind: :timeout,
                     message: "RLM runtime budget exhausted"
                   },
                   decision: %{action: :request_budget_approval}
                 },
                 objective_decision: %{action: :request_budget_approval},
                 open_tasks: [
                   %{id: "compile", title: "mix compile still fails", status: :open}
                 ],
                 completed_tasks: [
                   %{id: "plan", title: "Write implementation plan", status: :completed}
                 ],
                 budget_requests: [
                   %{reason: "repair budget exhausted before objective satisfaction"}
                 ]
               },
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.objective_loop.status == "needs_budget_approval"
    assert snapshot.objective_loop.action == "request_budget_approval"
    assert snapshot.objective_loop.objective == "Build OpsLogic"
    assert snapshot.objective_loop.iteration_count == 2
    assert snapshot.objective_loop.latest_error_kind == "timeout"
    assert snapshot.objective_loop.latest_error_message == "RLM runtime budget exhausted"
    assert [%{"id" => "compile"}] = snapshot.objective_loop.open_tasks
    assert [%{"id" => "plan"}] = snapshot.objective_loop.completed_tasks

    assert [%{"reason" => "repair budget exhausted before objective satisfaction"}] =
             snapshot.objective_loop.budget_requests
  end

  test "session snapshot exposes durable objective-loop review approval state" do
    session_id = unique_session_id("objective-review")

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("objective-review"),
               session_id: session_id,
               run_id: session_id,
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :review,
               title: "Objective review approval required",
               detail: "status: needs_review_approval",
               data_json: %{
                 run_id: session_id,
                 objective_iteration_count: 1,
                 objective_session: %{
                   id: session_id,
                   objective: "Plan OpsLogic",
                   status: :needs_review_approval,
                   iteration_count: 1,
                   max_iterations: 2,
                   latest_review_request: %{
                     kind: :objective_plan_approval,
                     resume_key: "review:opslogic:plan",
                     checkpoint: :plan_review
                   },
                   decision: %{action: :request_review_approval}
                 },
                 objective_decision: %{action: :request_review_approval},
                 objective_session_state: %{
                   id: session_id,
                   objective: "Plan OpsLogic",
                   status: :needs_review_approval,
                   created_at: DateTime.utc_now(),
                   updated_at: DateTime.utc_now(),
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
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.objective_loop.status == "needs_review_approval"
    assert snapshot.objective_loop.action == "request_review_approval"
    assert snapshot.objective_loop.objective == "Plan OpsLogic"
    assert snapshot.objective_loop.latest_review_request["resume_key"] == "review:opslogic:plan"
    assert [%{"checkpoint" => "plan_review"}] = snapshot.objective_loop.review_requests

    assert objective_session = Workbench.latest_objective_session(session_id)
    assert objective_session.status == :needs_review_approval
    assert objective_session.metadata == %{"plan_path" => "tmp/ops_logic/PLAN.md"}
    assert [%{"resume_key" => "review:opslogic:plan"}] = objective_session.review_requests
  end

  test "session approve-all policy approves pending non-budget reviews only" do
    session_id = unique_session_id("approval-policy")

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("approval-policy"),
               session_id: session_id,
               run_id: session_id,
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :review,
               title: "Objective review approval required",
               detail: "status: needs_review_approval",
               data_json: %{
                 run_id: session_id,
                 objective_decision: %{action: :request_review_approval},
                 review_requests: [
                   %{
                     kind: :guard_review,
                     resume_key: "review:tool:#{session_id}",
                     checkpoint: :pre_tool
                   }
                 ]
               },
               at: DateTime.utc_now()
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("approval-policy-budget"),
               session_id: session_id,
               run_id: session_id,
               agent: :rlm,
               kind: :summary,
               phase: :objective_loop,
               status: :review,
               title: "Objective budget approval required",
               detail: "status: needs_budget_approval",
               data_json: %{
                 run_id: session_id,
                 objective_decision: %{action: :request_budget_approval},
                 budget_requests: [
                   %{
                     kind: :objective_budget_approval,
                     resume_key: "budget:#{session_id}:1",
                     checkpoint: :budget_approval
                   }
                 ]
               },
               at: DateTime.utc_now()
             })

    assert {:ok, %{policy: :always, approved_count: 1}} =
             Workbench.record_approval_policy(session_id, %{"policy" => "always"})

    snapshot = Workbench.session_snapshot(session_id)

    assert Enum.any?(
             snapshot.review_requests,
             &(&1.id == "review:tool:#{session_id}" and &1.status == "approved")
           )

    assert Enum.any?(
             snapshot.review_requests,
             &(&1.id == "budget:#{session_id}:1" and &1.status == "pending")
           )

    assert snapshot.session.metadata["runtime_approval"] == "always"
  end

  test "records core events without requiring the web layer to consume terminal events" do
    session_id = unique_session_id("core-event")
    :ok = Workbench.subscribe_session(session_id)

    event =
      Event.workflow_effect!(:analysis,
        id: unique_event_id("core-analysis"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        source_step: :analysis,
        content: "Core analysis progress"
      )

    assert {:ok, _event} = Workbench.record_event(event)
    assert_receive {:workbench, :event, %Event{session_id: ^session_id, kind: :message}}

    assert snapshot = Workbench.session_snapshot(session_id)

    assert [%{kind: "analysis", transient: true, content: "Core analysis progress"}] =
             snapshot.messages

    assert snapshot.metrics.events == 1
  end

  test "session snapshot keeps transient workflow outputs and assistant summaries out of chat" do
    session_id = unique_session_id("visible-chat")
    at = ~U[2026-05-05 18:49:41Z]

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("intermediate"),
               session_id: session_id,
               run_id: session_id,
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
                   node_id: "assistant_node_7_synthesize",
                   type: :llm_leaf,
                   output: %{text: "I only have one notes block and no repo context."}
                 }
               },
               at: at
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("transient-final"),
               session_id: session_id,
               run_id: session_id,
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
                   node_id: "assistant_node_6_synthesize_report",
                   type: :llm_leaf,
                   output: %{text: "# Durably Merged Repo Report\n\nTransient copy."}
                 }
               },
               at: DateTime.add(at, 1, :second)
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("completed"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :rlm_plan,
               phase: :completed,
               status: :ok,
               title: "Assistant RLM Completed ok",
               detail: "completed",
               data_json: %{
                 stage: :completed,
                 status: :ok,
                 data: %{output_text: "# Durably Merged Repo Report\n\nFinal copy."}
               },
               at: DateTime.add(at, 2, :second)
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("scorecard"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :summary,
               phase: :scorecard,
               status: :ok,
               title: "Assistant RLM objective objective_satisfied",
               detail: "changed=0 risks=0",
               data_json: %{scorecard: %{objective_status: :objective_satisfied}},
               at: DateTime.add(at, 3, :second)
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("final"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :summary,
               phase: :final,
               status: :ok,
               title: "Agent finished",
               detail: "status: ok",
               data_json: %{},
               at: DateTime.add(at, 4, :second)
             })

    assert snapshot = Workbench.session_snapshot(session_id)
    assert [%{kind: "workflow_output", content: content, transient: false}] = snapshot.messages
    assert content == "# Durably Merged Repo Report\n\nFinal copy."
    assert snapshot.metrics.messages == 1
    assert snapshot.metrics.events == 5
  end

  test "session snapshot deduplicates equivalent assistant final workflow outputs" do
    session_id = unique_session_id("dedupe-final")
    content = "# Comparison Report\n\n- Response target is one business day."
    at = ~U[2026-05-09 18:30:00Z]

    for {label, kind, phase, data, offset} <- [
          {"completed", :rlm_plan, :completed,
           %{stage: :completed, data: %{output_text: content}}, 0},
          {"final", :message, :assistant,
           %{
             role: "assistant",
             message_kind: "workflow_output",
             content: content,
             output_text: content,
             blocked?: false
           }, 1}
        ] do
      assert {:ok, _event} =
               Workbench.record_terminal_event(%{
                 id: unique_event_id(label),
                 session_id: session_id,
                 run_id: session_id,
                 agent: :assistant,
                 kind: kind,
                 phase: phase,
                 status: :ok,
                 title: "Assistant output",
                 detail: content,
                 data_json: data,
                 at: DateTime.add(at, offset, :second)
               })
    end

    assert %{messages: [%{content: ^content}], metrics: %{messages: 1}} =
             Workbench.session_snapshot(session_id)
  end

  test "starts a browser-owned assistant run with the configured runner function" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("launch")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Reply from the browser",
               "agent" => "assistant",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify",
               "model_provider" => "openai",
               "model_id" => "gpt-5.4-mini",
               "max_runtime_ms" => "123456"
             })

    assert run_id != session_id

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      assert snapshot.session.model == "openai:gpt-5.4-mini"

      assert Enum.any?(
               snapshot.messages,
               &(&1.role == "user" and &1.content == "Reply from the browser")
             )

      assert Enum.any?(snapshot.messages, &String.contains?(&1.content, "Browser run complete"))
      assert Enum.any?(snapshot.events, &(&1.phase == "direct_response_completed"))

      assert Enum.any?(
               snapshot.events,
               &(&1.run_id == run_id and get_in(&1.data, ["max_runtime_ms"]) == 123_456)
             )

      assert Enum.any?(
               snapshot.events,
               &(&1.run_id == run_id and get_in(&1.data, ["write_policy"]) == "docs_only")
             )

      assert Enum.any?(snapshot.runs, &(&1.id == run_id))
    end)
  end

  test "browser launch records enabled sandbox code execution configuration" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("sandbox-launch")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Run sandboxed code from the browser",
               "agent" => "standard",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify",
               "profile" => "local-workbench",
               "toolsets" => "code_execution",
               "tool_config" => %{
                 "code_execution" => %{
                   "enabled" => true,
                   "state_model" => "persistent_workspace",
                   "transport_model" => "docker_cli",
                   "checkpoint_policy" => %{"mode" => "manual"}
                 }
               },
               "sandbox_profile" => "docker",
               "sandbox_backend" => "docker",
               "sandbox_runtime" => "python",
               "sandbox_runtimes" => "bash,python,node,elixir,lua",
               "sandbox_network" => "restricted",
               "sandbox_stateful" => "true",
               "sandbox_pool_warm" => "1",
               "sandbox_pool_max" => "2"
             })

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      launch_event =
        Enum.find(snapshot.events, fn event ->
          event.title == "Workbench run queued" and get_in(event.data, ["run_id"]) == run_id
        end)

      assert launch_event
      assert get_in(launch_event.data, ["toolsets"]) == ["code_execution"]
      assert get_in(launch_event.data, ["tool_config", "code_execution", "enabled"]) == true
      assert get_in(launch_event.data, ["tool_config", "code_execution", "backend"]) == "docker"

      assert get_in(launch_event.data, ["tool_config", "code_execution", "allowed_runtimes"]) == [
               "bash",
               "python",
               "node",
               "elixir",
               "lua"
             ]

      assert get_in(launch_event.data, ["tool_config", "code_execution", "network"]) ==
               "restricted"

      assert get_in(launch_event.data, ["sandbox", "backend"]) == "docker"
      assert get_in(launch_event.data, ["sandbox", "sandbox"]) == "docker"

      assert get_in(launch_event.data, ["sandbox", "runtimes"]) == [
               "bash",
               "python",
               "node",
               "elixir",
               "lua"
             ]

      assert get_in(launch_event.data, ["sandbox", "network"]) == "restricted"
      assert get_in(launch_event.data, ["sandbox", "stateful?"]) == true
      assert get_in(launch_event.data, ["sandbox", "pool"]) == %{"max" => 2, "warm" => 1}

      visible_tools = get_in(launch_event.data, ["capability_profile", "visible_tools"])
      assert "execute_code" in visible_tools
      assert "sandbox_status" in visible_tools

      capability_event =
        Enum.find(snapshot.events, fn event ->
          event.phase == "capability_profile_updated" and get_in(event.data, ["run_id"]) == run_id
        end)

      assert capability_event
      assert get_in(capability_event.data, ["sandbox", "backend"]) == "docker"
      assert get_in(capability_event.data, ["sandbox", "stateful?"]) == true
    end)
  end

  test "browser sandbox fields enable code execution without explicit toolsets" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("sandbox-implicit-toolset")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Implement a sandboxed Elixir coding slice",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "patch",
               "profile" => "coding-patch",
               "sandbox_backend" => "docker",
               "sandbox_runtime" => "elixir",
               "sandbox_network" => "host",
               "sandbox_stateful" => "true",
               "sandbox_pool_warm" => "1",
               "sandbox_pool_max" => "1"
             })

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      launch_event =
        Enum.find(snapshot.events, fn event ->
          event.title == "Workbench run queued" and get_in(event.data, ["run_id"]) == run_id
        end)

      assert launch_event
      assert get_in(launch_event.data, ["toolsets"]) == []
      assert get_in(launch_event.data, ["tool_config", "code_execution", "enabled"]) == true

      profile = get_in(launch_event.data, ["capability_profile"])
      assert "code_execution" in get_in(profile, ["toolsets"])
      assert "execute_code" in get_in(profile, ["visible_tools"])
      assert "sandbox_exec" in get_in(profile, ["visible_tools"])

      assert get_in(launch_event.data, ["sandbox", "backend"]) == "docker"
      assert get_in(launch_event.data, ["sandbox", "runtimes"]) == ["elixir"]
    end)
  end

  test "browser launch preserves approve-all and vmsan sandbox metadata" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("approve-all-vmsan")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Implement a small Elixir workspace change",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "always",
               "mode" => "patch",
               "write_policy" => "workspace_review",
               "profile" => "local-workbench",
               "sandbox_profile" => "local_code",
               "sandbox_backend" => "vmsan",
               "sandbox_runtime" => "elixir",
               "sandbox_runtimes" => "bash,python,node,elixir,lua",
               "sandbox_network" => "disabled",
               "sandbox_stateful" => "true",
               "sandbox_pool_warm" => "0",
               "sandbox_pool_max" => "2"
             })

    assert String.starts_with?(run_id, "rlm:web")

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      assert snapshot.session.status in ["running", "completed"]
      assert snapshot.session.metadata["approval"] == "always"
      assert snapshot.session.metadata["runtime_approval"] == "always"
      assert snapshot.session.metadata["mode"] == "patch"
      assert snapshot.session.metadata["write_policy"] == "workspace_review"

      sandbox = snapshot.session.metadata["sandbox"]
      assert sandbox["backend"] == "vmsan"
      assert sandbox["runtime"] == "elixir"
      assert sandbox["runtimes"] == ["bash", "python", "node", "elixir", "lua"]
      assert sandbox["network"] == "disabled"
      assert sandbox["stateful?"] == true
      assert sandbox["pool"] == %{"max" => 2, "warm" => 0}

      assert Enum.any?(snapshot.events, fn event ->
               event.run_id == run_id and event.phase == "capability_profile_updated"
             end)
    end)
  end

  test "browser follow-up messages stay in the session with distinct turn runs" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("follow-up")

    assert {:ok, %{session_id: ^session_id, run_id: first_run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "First browser request",
               "agent" => "assistant",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify"
             })

    eventually(fn ->
      assert Workbench.session_snapshot(session_id).messages
             |> Enum.any?(&String.contains?(&1.content, "First browser request"))
    end)

    assert {:ok, %{session_id: ^session_id, run_id: second_run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Second browser request",
               "agent" => "assistant",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify"
             })

    assert first_run_id != second_run_id
    assert first_run_id != session_id
    assert second_run_id != session_id

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      user_messages =
        snapshot.messages
        |> Enum.filter(&(&1.role == "user"))
        |> Enum.map(& &1.content)

      assert "First browser request" in user_messages
      assert "Second browser request" in user_messages

      run_ids = Enum.map(snapshot.runs, & &1.id)
      assert first_run_id in run_ids
      assert second_run_id in run_ids
    end)
  end

  test "browser agent switches keep prior conversation history for the new agent" do
    previous = Application.get_env(:runic_ai, :workbench, [])
    caller = self()

    run_fun = fn _cwd, objective, opts ->
      send(caller, {:agent_run, objective, opts[:conversation_history] || []})

      reply =
        if String.contains?(objective, "Plan") do
          "Plan: build the game with Phoenix LiveView, DynamicSupervisor, GameSessionServer, ECS tables, and ReqLLM."
        else
          "Implementation run received."
        end

      Keyword.fetch!(opts, :event_sink).(%{
        stage: :direct_response_completed,
        status: :ok,
        data: %{reply_text: reply, output: %{text_preview: reply}}
      })

      {:ok,
       %{scorecard: %{objective_status: :objective_satisfied}, artifacts: [], repair_history: []}}
    end

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, run_fun)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("agent-switch-history")

    prior_run_id = "standard:web:prior-plan"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("standard-user-plan"),
               session_id: session_id,
               run_id: prior_run_id,
               agent: :standard,
               kind: :message,
               phase: :user,
               status: :ok,
               title: "User request",
               detail: "Plan the LiveView text adventure architecture",
               data_json: %{
                 run_id: prior_run_id,
                 role: "user",
                 message_kind: "objective",
                 content: "Plan the LiveView text adventure architecture",
                 presentation_group_id: prior_run_id
               },
               at: DateTime.utc_now()
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("standard-assistant-plan"),
               session_id: session_id,
               run_id: prior_run_id,
               agent: :standard,
               kind: :message,
               phase: :assistant,
               status: :ok,
               title: "Assistant response",
               detail:
                 "Plan: build the game with Phoenix LiveView, DynamicSupervisor, GameSessionServer, ECS tables, and ReqLLM.",
               data_json: %{
                 run_id: prior_run_id,
                 role: "assistant",
                 message_kind: "assistant",
                 content:
                   "Plan: build the game with Phoenix LiveView, DynamicSupervisor, GameSessionServer, ECS tables, and ReqLLM.",
                 presentation_group_id: prior_run_id
               },
               at: DateTime.utc_now()
             })

    assert {:ok, %{session_id: ^session_id, run_id: second_run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Implement this as described in the repo using ReqLLM",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "patch",
               "profile" => "coding-patch"
             })

    assert String.starts_with?(second_run_id, "rlm:web")

    assert_receive {:agent_run, "Implement this as described in the repo using ReqLLM", history},
                   1_000

    assert Enum.any?(history, &String.contains?(&1.content, "Plan the LiveView text adventure"))
    assert Enum.any?(history, &String.contains?(&1.content, "DynamicSupervisor"))
    assert Enum.any?(history, &(&1.role == "assistant"))
  end

  test "browser repo RLM requests without workspace cues route to assistant" do
    previous = Application.get_env(:runic_ai, :workbench, [])
    caller = self()

    run_fun = fn cwd, objective, opts ->
      send(caller, {:conversation_history, opts[:conversation_history]})
      fake_assistant_run(cwd, objective, opts)
    end

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, run_fun)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("rlm-route")

    objective =
      "Build a graph memory system for a Wandering Inn text adventure game."

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("prior-rlm-output"),
               session_id: session_id,
               run_id: "rlm:web:prior",
               agent: :rlm,
               kind: :message,
               phase: :assistant,
               status: :ok,
               title: "RLM final output",
               detail: "## File output\n\nAGENTS.md",
               data_json: %{
                 run_id: "rlm:web:prior",
                 role: "assistant",
                 message_kind: "workflow_output",
                 content: "## File output\n\nAGENTS.md",
                 presentation_group_id: "rlm:web:prior"
               },
               at: DateTime.utc_now()
             })

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => objective,
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify",
               "max_objective_iterations" => "4"
             })

    assert String.starts_with?(run_id, "assistant:web")
    assert_receive {:conversation_history, history}
    refute Enum.any?(history, &String.contains?(&1.content, "AGENTS.md"))

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      assert snapshot.session.agent == "assistant"
      assert Enum.any?(snapshot.messages, &(&1.role == "user" and &1.content == objective))
      assert Enum.any?(snapshot.messages, &String.contains?(&1.content, "Browser run complete"))

      assert Enum.any?(snapshot.events, fn event ->
               event.agent == "assistant" and
                 get_in(event.data, ["requested_agent"]) == "rlm" and
                 get_in(event.data, ["routed_agent"]) == "assistant" and
                 get_in(event.data, ["route_reason"]) == "non_workspace_rlm_objective"
             end)
    end)
  end

  test "browser repo RLM requests with workspace cues stay on the RLM runner" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("rlm-route-code")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Inspect the RunicAI repo tests for failures",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify",
               "max_objective_iterations" => "4"
             })

    assert String.starts_with?(run_id, "rlm:web")

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      assert snapshot.session.agent == "rlm"

      assert Enum.any?(snapshot.events, fn event ->
               event.title == "Workbench run queued" and
                 get_in(event.data, ["run_id"]) == run_id and
                 get_in(event.data, ["max_objective_iterations"]) in [4, "4"]
             end)

      assert Enum.any?(snapshot.events, fn event ->
               get_in(event.data, ["run_id"]) == run_id and
                 event.phase == "objective_loop" and
                 event.title == "Objective satisfied" and
                 get_in(event.data, ["objective_session_state", "max_iterations"]) in [4, "4"]
             end)

      refute Enum.any?(
               snapshot.events,
               &(get_in(&1.data, ["route_reason"]) == "non_workspace_rlm_objective")
             )
    end)
  end

  test "browser RLM patch requests stay on the RLM runner even as follow-up prose" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("rlm-patch-follow-up")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Now implement this implementation plan as described.",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "patch",
               "profile" => "local-workbench",
               "write_policy" => "workspace_review"
             })

    assert String.starts_with?(run_id, "rlm:web")

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      assert snapshot.session.agent == "rlm"

      assert Enum.any?(snapshot.events, fn event ->
               event.run_id == run_id and
                 get_in(event.data, ["mode"]) == "patch" and
                 get_in(event.data, ["write_policy"]) == "workspace_review" and
                 get_in(event.data, ["profile"]) == "local-workbench"
             end)

      refute Enum.any?(
               snapshot.events,
               &(get_in(&1.data, ["route_reason"]) == "non_workspace_rlm_objective")
             )
    end)
  end

  test "browser objective-loop review approval resumes the persisted RLM objective" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_objective_loop_review_run/3)
      |> Keyword.put(:max_runtime_ms, 3_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("objective-review-resume")
    review_id = "review:objective-plan:#{session_id}"

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Plan and implement OpsLogic code under ./tmp/ops_logic",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "ask",
               "mode" => "patch"
             })

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)

        assert %{status: "needs_review_approval", action: "request_review_approval"} =
                 snapshot.objective_loop

        assert [%{"resume_key" => ^review_id, "status" => "pending"}] =
                 snapshot.objective_loop.pending_review_requests

        assert [%{id: ^review_id, status: "pending"}] = snapshot.review_requests
        assert latest = Workbench.latest_objective_session(session_id)
        assert latest.status == :needs_review_approval
        assert length(latest.iterations) == 1
      end,
      120
    )

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, review_id, %{
               "id" => review_id,
               "action" => "approve"
             })

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)
        latest = Workbench.latest_objective_session(session_id)

        assert latest.status == :objective_satisfied
        assert length(latest.iterations) == 2
        assert snapshot.objective_loop.status == "objective_satisfied"
        assert snapshot.objective_loop.action == "complete"
        assert snapshot.objective_loop.pending_review_requests == []

        assert [%{"resume_key" => ^review_id, "status" => "approved"}] =
                 snapshot.objective_loop.review_requests

        assert Enum.any?(snapshot.events, fn event ->
                 event.run_id == run_id and event.phase == "objective_loop_resume"
               end)

        assert [%{id: ^review_id, status: "approved"}] = snapshot.review_requests
      end,
      120
    )

    assert {:error, :review_already_decided} =
             Workbench.record_review_decision(session_id, review_id, %{
               "id" => review_id,
               "action" => "approve"
             })
  end

  test "approval policy change carries approve-all into objective resume runs" do
    previous = Application.get_env(:runic_ai, :workbench, [])
    parent = self()

    run_fun = fn _cwd, objective, opts ->
      case Keyword.fetch!(opts, :objective_iteration) do
        1 ->
          request =
            ReviewRequest.new!(:objective_plan_approval,
              checkpoint: :plan_review,
              resume_key: "review:objective-policy:#{opts[:session_id]}",
              options: [:approve, :reject, :edit, :cancel],
              details: %{objective_preview: objective},
              metadata: %{safe?: false, source: :objective_loop_policy_test}
            )

          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_incomplete},
             review_request: request,
             context: %{changed_files: ["PLAN.md"]}
           }}

        2 ->
          send(
            parent,
            {:objective_resume_opts, opts[:approval], is_function(opts[:review_decider], 2)}
          )

          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_satisfied},
             context: %{changed_files: ["lib/demo.ex"]}
           }}
      end
    end

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, run_fun)
      |> Keyword.put(:max_runtime_ms, 3_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("objective-policy-resume")
    review_id = "review:objective-policy:#{session_id}"

    assert {:ok, %{session_id: ^session_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Plan and implement policy resume code",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "ask",
               "mode" => "patch"
             })

    eventually(fn ->
      assert %{objective_loop: %{status: "needs_review_approval"}} =
               Workbench.session_snapshot(session_id)

      assert [%{id: ^review_id, status: "pending"}] =
               Workbench.session_snapshot(session_id).review_requests
    end)

    assert {:ok, %{policy: :always, approved_count: 1}} =
             Workbench.record_approval_policy(session_id, %{"policy" => "always"})

    assert_receive {:objective_resume_opts, :always, true}, 1_000

    eventually(fn ->
      assert %{objective_loop: %{status: "objective_satisfied", action: "complete"}} =
               Workbench.session_snapshot(session_id)
    end)
  end

  test "review decisions preserve the selected session agent in the projection" do
    session_id = unique_session_id("review-agent")
    review_id = unique_event_id("review-agent")

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("start"),
               session_id: session_id,
               run_id: session_id,
               agent: :rlm,
               kind: :status,
               phase: :session,
               status: :running,
               title: "RLM session started",
               detail: "preserve agent",
               data_json: %{
                 run_id: session_id,
                 objective: "Preserve RLM review attribution",
                 model: "test:model",
                 approve: :ask,
                 mode: :patch
               },
               at: DateTime.utc_now()
             })

    seed_review_request(session_id, review_id)

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, review_id, %{
               "id" => review_id,
               "action" => "deny"
             })

    snapshot = Workbench.session_snapshot(session_id)

    assert snapshot.session.agent == "rlm"
    assert snapshot.session.status == "blocked"
    assert [%{id: ^review_id, status: "denied"}] = snapshot.review_requests

    assert %{agent: "rlm", phase: "review_decision", status: "blocked"} =
             List.last(snapshot.events)
  end

  test "browser objective-loop budget approval resumes the persisted RLM objective" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_objective_loop_budget_run/3)
      |> Keyword.put(:max_runtime_ms, 3_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("objective-budget-resume")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Implement OpsLogic code under ./tmp/ops_logic",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "ask",
               "mode" => "patch",
               "max_objective_iterations" => "1"
             })

    budget_id = "budget:#{run_id}:1"

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)

        assert %{status: "needs_budget_approval", action: "request_budget_approval"} =
                 snapshot.objective_loop

        assert [%{"id" => ^budget_id, "status" => "pending"}] =
                 snapshot.objective_loop.pending_budget_requests

        assert [%{id: ^budget_id, status: "pending"}] = snapshot.review_requests
        assert latest = Workbench.latest_objective_session(session_id)
        assert latest.status == :needs_budget_approval
        assert length(latest.iterations) == 1
      end,
      120
    )

    before_approval = Workbench.latest_objective_session(session_id)

    before_deadline =
      before_approval.metadata[:run_deadline_ms] || before_approval.metadata["run_deadline_ms"]

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, budget_id, %{
               "id" => budget_id,
               "action" => "approve",
               "additional_iterations" => "2",
               "additional_runtime_ms" => "1500",
               "approved_runtime_ms" => "1700",
               "max_runtime_ms" => "4500"
             })

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)
        latest = Workbench.latest_objective_session(session_id)

        assert latest.status == :objective_satisfied
        assert latest.max_iterations >= 3
        assert (latest.metadata[:max_runtime_ms] || latest.metadata["max_runtime_ms"]) == 4_500
        latest_deadline = latest.metadata[:run_deadline_ms] || latest.metadata["run_deadline_ms"]
        assert is_integer(latest_deadline)

        if before_deadline do
          assert latest_deadline > before_deadline
        end

        assert length(latest.iterations) == 2
        assert snapshot.objective_loop.status == "objective_satisfied"
        assert snapshot.objective_loop.action == "complete"
        assert snapshot.objective_loop.pending_budget_requests == []

        assert [%{"id" => ^budget_id, "status" => "approved"}] =
                 snapshot.objective_loop.budget_requests

        assert Enum.any?(snapshot.events, fn event ->
                 event.run_id == run_id and event.phase == "objective_loop_resume"
               end)

        assert [%{id: ^budget_id, status: "approved", decision: decision}] =
                 snapshot.review_requests

        assert decision["additional_iterations"] == "2"
        assert decision["additional_runtime_ms"] == "1500"
        assert decision["approved_runtime_ms"] == "1700"
        assert decision["max_runtime_ms"] == "4500"
      end,
      120
    )

    assert {:error, :review_already_decided} =
             Workbench.record_review_decision(session_id, budget_id, %{
               "id" => budget_id,
               "action" => "approve"
             })
  end

  test "browser objective-loop review denial records blocked state without resuming work" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_objective_loop_review_run/3)
      |> Keyword.put(:max_runtime_ms, 3_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("objective-review-deny")
    review_id = "review:objective-plan:#{session_id}"

    assert {:ok, %{session_id: ^session_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Plan and implement OpsLogic code under ./tmp/ops_logic",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "ask",
               "mode" => "patch"
             })

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)

        assert %{status: "needs_review_approval", action: "request_review_approval"} =
                 snapshot.objective_loop

        assert [%{id: ^review_id, status: "pending"}] = snapshot.review_requests
      end,
      120
    )

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, review_id, %{
               "id" => review_id,
               "action" => "deny"
             })

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)
        latest = Workbench.latest_objective_session(session_id)

        assert latest.status == :blocked
        assert length(latest.iterations) == 1
        assert snapshot.objective_loop.status == "blocked"
        assert snapshot.objective_loop.action == "stop_blocked"
        assert snapshot.objective_loop.pending_review_requests == []

        assert [%{"resume_key" => ^review_id, "status" => "rejected"}] =
                 snapshot.objective_loop.review_requests

        assert [%{id: ^review_id, status: "denied"}] = snapshot.review_requests
      end,
      120
    )

    assert {:error, :review_already_decided} =
             Workbench.record_review_decision(session_id, review_id, %{
               "id" => review_id,
               "action" => "approve"
             })
  end

  test "browser objective-loop budget cancellation records blocked state without more iterations" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_objective_loop_budget_run/3)
      |> Keyword.put(:max_runtime_ms, 3_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("objective-budget-stop")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Implement OpsLogic code under ./tmp/ops_logic",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "ask",
               "mode" => "patch",
               "max_objective_iterations" => "1"
             })

    budget_id = "budget:#{run_id}:1"

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)

        assert %{status: "needs_budget_approval", action: "request_budget_approval"} =
                 snapshot.objective_loop

        assert [%{id: ^budget_id, status: "pending"}] = snapshot.review_requests
      end,
      120
    )

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, budget_id, %{
               "id" => budget_id,
               "action" => "stop"
             })

    eventually(
      fn ->
        snapshot = Workbench.session_snapshot(session_id)
        latest = Workbench.latest_objective_session(session_id)

        assert latest.status == :blocked
        assert latest.max_iterations == 1
        assert length(latest.iterations) == 1
        assert snapshot.objective_loop.status == "blocked"
        assert snapshot.objective_loop.action == "stop_blocked"
        assert snapshot.objective_loop.pending_budget_requests == []

        assert [%{"id" => ^budget_id, "status" => "cancelled"}] =
                 snapshot.objective_loop.budget_requests

        assert [%{id: ^budget_id, status: "cancelled"}] = snapshot.review_requests
      end,
      120
    )

    assert {:error, :review_already_decided} =
             Workbench.record_review_decision(session_id, budget_id, %{
               "id" => budget_id,
               "action" => "approve"
             })
  end

  test "browser approval ask creates a pending review and resumes after browser decision" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_browser_review_run/3)
      |> Keyword.put(:max_runtime_ms, 2_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("browser-review")
    review_id = "review:browser-artifact:#{session_id}"

    assert {:ok, %{session_id: ^session_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Write .docs/browser-review.md after approval",
               "agent" => "assistant",
               "cwd" => File.cwd!(),
               "approve" => "ask",
               "mode" => "verify"
             })

    eventually(fn ->
      assert %{review_requests: [%{id: ^review_id, status: "pending"}]} =
               Workbench.session_snapshot(session_id)
    end)

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, review_id, %{
               "action" => "approve"
             })

    eventually(fn ->
      assert %{review_requests: [%{status: "approved"}], messages: messages} =
               Workbench.session_snapshot(session_id)

      assert Enum.any?(messages, &String.contains?(&1.content, "artifact_written"))
    end)
  end

  test "records browser review decisions as durable review history" do
    for {action, expected_status} <- [
          {"approve", "approved"},
          {"deny", "denied"},
          {"stop", "cancelled"},
          {"rewrite", "approved"}
        ] do
      session_id = unique_session_id("review-#{action}")
      review_id = "review:#{session_id}"
      seed_review_request(session_id, review_id)

      params =
        case action do
          "rewrite" -> %{"action" => action, "rewrite" => "Use a safer command."}
          _other -> %{"action" => action, "rewrite" => ""}
        end

      assert {:ok, _event} = Workbench.record_review_decision(session_id, review_id, params)

      assert %{review_requests: [%{status: ^expected_status, decision: decision}]} =
               Workbench.session_snapshot(session_id)

      assert decision["decision"] == action
    end
  end

  def fake_assistant_run(_cwd, objective, opts) do
    event_sink = Keyword.fetch!(opts, :event_sink)

    event_sink.(%{
      stage: :direct_response_completed,
      status: :ok,
      data: %{
        reply_text: "Browser run complete: #{objective}",
        output: %{text_preview: "Browser run complete: #{objective}"}
      }
    })

    {:ok,
     %{
       scorecard: %{objective_status: :objective_satisfied},
       artifacts: [],
       repair_history: []
     }}
  end

  def fake_browser_review_run(_cwd, _objective, opts) do
    review_id = "review:browser-artifact:#{opts[:session_id]}"

    request =
      ReviewRequest.new!(:assistant_artifact_write,
        checkpoint: :pre_write,
        resume_key: review_id,
        options: [:approve, :reject, :edit, :cancel],
        details: %{
          path: ".docs/browser-review.md",
          write_policy: :docs_only,
          input_preview: %{text_preview: "# Browser Review"}
        },
        metadata: %{safe?: true, risk: :low}
      )

    {:ok, decision} = opts[:review_decider].(request, %{session_id: opts[:session_id]})

    output =
      case decision.status do
        :approved -> "artifact_written: .docs/browser-review.md"
        status -> "artifact_not_written: #{status}"
      end

    {:ok,
     %{
       output_text: output,
       scorecard: %{objective_status: :objective_satisfied},
       artifacts: [],
       repair_history: []
     }}
  end

  def fake_objective_loop_review_run(_cwd, objective, opts) do
    case Keyword.fetch!(opts, :objective_iteration) do
      1 ->
        request =
          ReviewRequest.new!(:objective_plan_approval,
            checkpoint: :plan_review,
            resume_key: "review:objective-plan:#{opts[:session_id]}",
            options: [:approve, :reject, :edit, :cancel],
            details: %{path: "tmp/ops_logic/PLAN.md", objective_preview: objective},
            metadata: %{safe?: false, source: :objective_loop_test}
          )

        {:ok,
         %{
           objective_scorecard: %{objective_status: :objective_satisfied},
           review_request: request,
           context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
         }}

      2 ->
        {:ok,
         %{
           objective_scorecard: %{objective_status: :objective_satisfied},
           context: %{changed_files: ["tmp/ops_logic/mix.exs"]}
         }}
    end
  end

  def fake_objective_loop_budget_run(_cwd, objective, opts) do
    case Keyword.fetch!(opts, :objective_iteration) do
      1 ->
        {:ok,
         %{
           objective_scorecard: %{objective_status: :objective_incomplete},
           context: %{
             task_updates: [%{id: "plan", title: "Plan OpsLogic", status: :completed}],
             repair_needs: [
               %{
                 id: "implementation",
                 reason: "implementation needs another objective iteration",
                 target: "tmp/ops_logic"
               }
             ]
           }
         }}

      2 ->
        assert objective =~ "operator budget approval"

        {:ok,
         %{
           objective_scorecard: %{objective_status: :objective_satisfied},
           context: %{changed_files: ["tmp/ops_logic/mix.exs"]}
         }}
    end
  end

  def fake_objective_loop_cap_budget_resume_run(_cwd, objective, opts) do
    assert Keyword.fetch!(opts, :objective_iteration) == 3
    assert objective =~ "operator budget approval"

    {:ok,
     %{
       objective_scorecard: %{objective_status: :objective_satisfied},
       context: %{changed_files: ["tmp/ops_logic/mix.exs"]}
     }}
  end

  defp seed_review_request(session_id, review_id) do
    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("review"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :hitl,
               phase: :review_requested,
               status: :review,
               title: "Review requested",
               detail: "review #{review_id}",
               data_json: %{
                 stage: :review_requested,
                 status: :review,
                 data: %{
                   id: review_id,
                   kind: :browser_review,
                   checkpoint: :pre_tool,
                   resume_key: review_id,
                   options: [:approve, :reject, :edit, :cancel],
                   details: %{tool_name: "apply_patch"}
                 }
               },
               at: DateTime.utc_now()
             })
  end

  defp eventually(fun, attempts \\ 40)

  defp eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    exception ->
      if attempts == 1 do
        reraise exception, __STACKTRACE__
      else
        Process.sleep(25)
        eventually(fun, attempts - 1)
      end
  end

  defp unique_session_id(label),
    do: "test:workbench:#{label}:#{System.unique_integer([:positive])}"

  defp unique_event_id(label), do: "test:event:#{label}:#{System.unique_integer([:positive])}"
end
