defmodule RunicAI.Coding.RLMObjectiveLoopTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.RLM.ObjectiveLoop
  alias RunicAI.Coding.RLM.ObjectiveSession
  alias RunicAI.Coding.RLM.EditOperation
  alias RunicAI.Coding.RLM.EditPatchSet
  alias RunicAI.Coding.RLM.ElixirProjectGenerator
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.RLM.Robustness.DeterministicChecks
  alias RunicAI.RLM.Robustness.ProjectScenario

  test "session completes only when the objective scorecard is satisfied" do
    session = ObjectiveSession.new!("Build OpsLogic", id: "objective-1")

    session =
      session
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_satisfied, changed_files: ["PLAN.md"]},
        context: %{changed_files: ["PLAN.md"]}
      })

    assert session.status == :objective_satisfied
    assert ObjectiveSession.terminal?(session)
    assert ObjectiveSession.decision(session).action == :complete
    assert ObjectiveSession.summary(session).completed_task_count == 1
  end

  test "repair budget exhaustion requests more budget instead of pretending success" do
    session = ObjectiveSession.new!("Implement project", max_iterations: 5)

    session =
      session
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        repair_status: :exhausted,
        objective_scorecard: %{objective_status: :objective_incomplete},
        context: %{
          repair_needs: [
            %{id: "compile", reason: "mix compile still fails", target: "compile_project"}
          ]
        }
      })

    decision = ObjectiveSession.decision(session)

    assert session.status == :needs_budget_approval
    assert decision.action == :request_budget_approval
    assert decision.request.reason == "repair budget exhausted before objective satisfaction"
    assert hd(session.open_tasks).id == "compile"
  end

  test "JSON-style runtime timeout results request budget approval" do
    session = ObjectiveSession.new!("Implement generated project", max_iterations: 5)

    session =
      session
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        "status" => "blocked",
        "objective_scorecard" => %{"objective_status" => "objective_incomplete"},
        "context" => %{
          "runtime_timeout" => %{
            "stage" => "implement_project",
            "elapsed_ms" => 60_000,
            "max_runtime_ms" => 60_000
          }
        }
      })

    decision = ObjectiveSession.decision(session)

    assert session.status == :needs_budget_approval
    assert decision.action == :request_budget_approval
    assert decision.request.reason == "runtime budget exhausted during active workflow execution"
    assert decision.request.current_iteration == 1
  end

  test "session persists explicit objective task updates across iterations" do
    session = ObjectiveSession.new!("Build OpsLogic", id: "objective-tasks")

    session =
      session
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_incomplete},
        context: %{
          task_updates: [
            %{id: "plan", title: "Write implementation plan", status: :completed},
            %{id: "web", title: "Build dispatcher LiveView", status: :in_progress}
          ]
        }
      })

    assert [%{id: "plan", status: :completed}] = session.completed_tasks
    assert [%{id: "web", status: :in_progress}] = session.open_tasks
    assert [%{id: "plan"}, %{id: "web"}] = hd(session.iterations).task_updates

    session =
      session
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_incomplete},
        task_updates: [%{id: "web", title: "Build dispatcher LiveView", status: :completed}]
      })

    assert Enum.any?(session.completed_tasks, &(&1.id == "plan"))
    assert Enum.any?(session.completed_tasks, &(&1.id == "web"))
    refute Enum.any?(session.open_tasks, &(&1.id == "web"))

    restored =
      session
      |> ObjectiveSession.to_map()
      |> ObjectiveSession.from_map!()

    assert Enum.any?(restored.completed_tasks, &(&1.id == "web"))
    refute Enum.any?(restored.open_tasks, &(&1.id == "web"))
  end

  test "session replaces stale open task state with latest objective task update" do
    session = ObjectiveSession.new!("Build OpsLogic", id: "objective-task-replace")

    session =
      session
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_incomplete},
        task_updates: [
          %{id: "web", title: "Build dispatcher LiveView", status: :in_progress}
        ]
      })

    assert [%{id: "web", title: "Build dispatcher LiveView", status: :in_progress}] =
             session.open_tasks

    session =
      session
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_incomplete},
        task_updates: [
          %{id: "web", title: "Repair dispatcher LiveView compile failure", status: :blocked}
        ]
      })

    assert [
             %{
               id: "web",
               title: "Repair dispatcher LiveView compile failure",
               status: :blocked
             }
           ] = session.open_tasks
  end

  test "objective loop continues with repair objective until satisfied" do
    runner = fn _workspace, objective, opts ->
      case Keyword.fetch!(opts, :objective_iteration) do
        1 ->
          assert objective == "Build OpsLogic"

          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_incomplete},
             context: %{
               repair_needs: [
                 %{id: "tests", reason: "meaningful tests missing", target: "test_project"}
               ]
             }
           }}

        2 ->
          assert objective =~ "meaningful tests missing"

          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_satisfied},
             context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
           }}
      end
    end

    assert {:ok, result} =
             ObjectiveLoop.run(:workspace, "Build OpsLogic",
               runner: runner,
               max_iterations: 3
             )

    assert result.decision.action == :complete
    assert result.session.status == :objective_satisfied
    assert length(result.session.iterations) == 2
  end

  test "objective loop shares one runtime deadline across workflow iterations" do
    {:ok, seen} = Elixir.Agent.start_link(fn -> [] end)

    runner = fn _workspace, _objective, opts ->
      Elixir.Agent.update(
        seen,
        &(&1 ++ [Keyword.take(opts, [:objective_iteration, :run_deadline_ms, :max_runtime_ms])])
      )

      case Keyword.fetch!(opts, :objective_iteration) do
        1 ->
          Process.sleep(10)

          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_incomplete},
             context: %{repair_needs: [%{id: "tests", reason: "tests still missing"}]}
           }}

        2 ->
          {:ok, %{objective_scorecard: %{objective_status: :objective_satisfied}}}
      end
    end

    assert {:ok, result} =
             ObjectiveLoop.run(:workspace, "Build OpsLogic",
               runner: runner,
               max_iterations: 3,
               max_runtime_ms: 1_000
             )

    assert result.decision.action == :complete

    [first, second] = Elixir.Agent.get(seen, & &1)
    assert first[:objective_iteration] == 1
    assert second[:objective_iteration] == 2
    assert is_integer(first[:run_deadline_ms])
    assert second[:run_deadline_ms] == first[:run_deadline_ms]
    assert is_integer(first[:max_runtime_ms])
    assert is_integer(second[:max_runtime_ms])
    assert second[:max_runtime_ms] < first[:max_runtime_ms]
  end

  test "objective loop persists runtime deadline through review resume" do
    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:deadline:plan",
        details: %{path: "tmp/ops_logic/PLAN.md"}
      )

    runner = fn _workspace, _objective, opts ->
      case Keyword.fetch!(opts, :objective_iteration) do
        1 ->
          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_satisfied},
             review_request: review_request
           }}

        2 ->
          send(self(), {:unexpected_self_send, opts})
          {:ok, %{objective_scorecard: %{objective_status: :objective_satisfied}}}
      end
    end

    assert {:ok, paused} =
             ObjectiveLoop.run(:workspace, "Plan OpsLogic",
               runner: runner,
               max_runtime_ms: 1_000
             )

    deadline = paused.session.metadata[:run_deadline_ms]
    assert is_integer(deadline)
    assert paused.session.metadata[:max_runtime_ms] == 1_000

    restored =
      paused.session
      |> ObjectiveSession.to_map()
      |> ObjectiveSession.from_map!()

    caller = self()

    resume_runner = fn _workspace, _objective, opts ->
      send(
        caller,
        {:review_resume_budget, Keyword.take(opts, [:run_deadline_ms, :max_runtime_ms])}
      )

      {:ok, %{objective_scorecard: %{objective_status: :objective_satisfied}}}
    end

    approved = ReviewDecision.new!("review:deadline:plan", :approved)

    assert {:ok, resumed} =
             ObjectiveLoop.resume_after_review(:workspace, restored, approved,
               runner: resume_runner
             )

    assert resumed.decision.action == :complete
    assert_receive {:review_resume_budget, budget}
    assert budget[:run_deadline_ms] == deadline
    assert is_integer(budget[:max_runtime_ms])
    assert budget[:max_runtime_ms] <= 1_000
  end

  test "budget approval can extend an expired durable runtime deadline" do
    expired_deadline = System.monotonic_time(:millisecond) - 100

    assert {:ok, paused} =
             ObjectiveLoop.run(:workspace, "Build OpsLogic",
               runner: fn _workspace, _objective, _opts ->
                 flunk("expired objective deadline should not start a workflow attempt")
               end,
               run_deadline_ms: expired_deadline
             )

    assert paused.decision.action == :request_budget_approval
    assert paused.session.metadata[:run_deadline_ms] == expired_deadline

    request = paused.decision.request
    assert request.current_iteration == 1
    assert request.resume_key =~ ":1"

    approved =
      ReviewDecision.new!(request.resume_key, :approved,
        metadata: %{additional_runtime_ms: 1_000, additional_iterations: 1}
      )

    caller = self()

    resume_runner = fn _workspace, _objective, opts ->
      send(
        caller,
        {:budget_resume_budget, Keyword.take(opts, [:run_deadline_ms, :max_runtime_ms])}
      )

      {:ok, %{objective_scorecard: %{objective_status: :objective_satisfied}}}
    end

    assert {:ok, resumed} =
             ObjectiveLoop.resume_after_budget(:workspace, paused.session, approved,
               runner: resume_runner
             )

    assert resumed.decision.action == :complete
    assert resumed.session.metadata[:run_deadline_ms] > expired_deadline
    assert_receive {:budget_resume_budget, budget}
    assert budget[:run_deadline_ms] == resumed.session.metadata[:run_deadline_ms]
    assert is_integer(budget[:max_runtime_ms])
    assert budget[:max_runtime_ms] > 0
  end

  test "objective loop requests budget instead of starting an iteration after runtime deadline" do
    caller = self()

    runner = fn _workspace, _objective, _opts ->
      send(caller, :unexpected_objective_iteration)
      {:ok, %{objective_scorecard: %{objective_status: :objective_satisfied}}}
    end

    assert {:ok, result} =
             ObjectiveLoop.run(:workspace, "Build OpsLogic",
               runner: runner,
               run_deadline_ms: System.monotonic_time(:millisecond) - 1
             )

    refute_received :unexpected_objective_iteration
    assert result.decision.action == :request_budget_approval
    assert result.decision.request.current_iteration == 1
    assert result.session.status == :needs_budget_approval
    assert result.latest_error.kind == :timeout
    assert result.latest_error.details.stage == :objective_loop
  end

  test "objective loop emits progress snapshots during each iteration" do
    {:ok, progress} = Elixir.Agent.start_link(fn -> [] end)

    runner = fn _workspace, _objective, opts ->
      case Keyword.fetch!(opts, :objective_iteration) do
        1 ->
          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_incomplete},
             context: %{repair_needs: [%{id: "tests", reason: "tests missing"}]}
           }}

        2 ->
          {:ok, %{objective_scorecard: %{objective_status: :objective_satisfied}}}
      end
    end

    assert {:ok, result} =
             ObjectiveLoop.run(:workspace, "Build OpsLogic",
               runner: runner,
               max_iterations: 3,
               objective_progress_sink: fn event ->
                 Elixir.Agent.update(progress, &(&1 ++ [event]))
               end
             )

    assert result.decision.action == :complete

    emitted = Elixir.Agent.get(progress, & &1)

    assert [:iteration_started, :iteration_completed, :iteration_started, :iteration_completed] =
             Enum.map(emitted, & &1.event)

    assert Enum.at(emitted, 0).current_iteration == 1
    assert Enum.at(emitted, 1).status == :running
    assert [%{id: "tests"}] = Enum.at(emitted, 1).open_tasks
    assert Enum.at(emitted, 3).status == :objective_satisfied
    assert Enum.at(emitted, 3).action == :complete
    assert Enum.at(emitted, 3).objective_session_state.status == :objective_satisfied
  end

  test "objective loop requests budget approval when iteration budget is exhausted" do
    runner = fn _workspace, _objective, _opts ->
      {:ok,
       %{
         objective_scorecard: %{objective_status: :objective_incomplete},
         context: %{
           repair_needs: [
             %{id: "source", reason: "source evidence missing", target: "implementation"}
           ]
         }
       }}
    end

    assert {:ok, result} =
             ObjectiveLoop.run(:workspace, "Build OpsLogic",
               runner: runner,
               max_iterations: 1
             )

    assert result.decision.action == :request_budget_approval
    assert result.session.status == :needs_budget_approval

    assert result.decision.request.reason ==
             "objective iteration budget exhausted before objective satisfaction"
  end

  test "objective loop resumes after budget approval with additional iterations" do
    runner = fn _workspace, objective, opts ->
      case Keyword.fetch!(opts, :objective_iteration) do
        1 ->
          assert objective == "Build OpsLogic"

          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_incomplete},
             context: %{repair_needs: [%{id: "compile", reason: "compile still fails"}]}
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

    assert {:ok, paused} =
             ObjectiveLoop.run(:workspace, "Build OpsLogic",
               runner: runner,
               max_iterations: 1
             )

    assert paused.decision.action == :request_budget_approval
    request = paused.decision.request

    approved =
      ReviewDecision.new!(request.resume_key, :approved, metadata: %{additional_iterations: 2})

    assert {:ok, resumed} =
             ObjectiveLoop.resume_after_budget(:workspace, paused.session, approved,
               runner: runner
             )

    assert resumed.decision.action == :complete
    assert resumed.session.status == :objective_satisfied
    assert resumed.session.max_iterations >= 3

    assert [%{status: :approved, resolved_at: %DateTime{}, decision: %{status: :approved}}] =
             resumed.session.budget_requests

    assert ObjectiveSession.summary(resumed.session).pending_budget_request_count == 0
    assert Enum.any?(resumed.session.progress_log, &(&1.event == :budget_completed))
  end

  test "budget approval resolves the pending request in the durable session" do
    session =
      ObjectiveSession.new!("Build OpsLogic", id: "budget-resolution", max_iterations: 1)
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_incomplete},
        context: %{repair_needs: [%{id: "compile", reason: "compile still fails"}]}
      })

    assert session.status == :needs_budget_approval
    assert [%{status: :pending} = request] = session.budget_requests
    assert ObjectiveSession.summary(session).pending_budget_request_count == 1

    decision =
      ReviewDecision.new!(request.resume_key, :approved,
        actor: "dispatcher",
        metadata: %{additional_iterations: 2}
      )

    assert {:ok, approved} = ObjectiveSession.record_budget_decision(session, decision)

    assert approved.status == :planning
    assert approved.max_iterations >= 3

    assert [
             %{
               id: "budget:budget-resolution:1",
               status: :approved,
               resolved_at: %DateTime{},
               decision: %{status: :approved, actor: "dispatcher"}
             }
           ] = approved.budget_requests

    assert ObjectiveSession.summary(approved).pending_budget_request_count == 0
    assert ObjectiveSession.decision(approved).action == :continue

    assert {:error, error} = ObjectiveSession.record_budget_decision(approved, decision)
    assert error.message == "objective session is not waiting for budget approval"
  end

  test "timeout errors become budget approval requests" do
    session =
      ObjectiveSession.new!("Run long repair")
      |> Map.put(:latest_result, %{
        objective_scorecard: %{objective_status: :objective_incomplete}
      })
      |> Map.put(:next_objective, "stale continuation objective")

    session =
      ObjectiveSession.record_error(
        session,
        Error.timeout("RLM runtime budget exhausted", details: %{stage: :repair})
      )

    assert session.status == :needs_budget_approval
    assert session.latest_result == nil
    assert session.next_objective == nil
    assert ObjectiveSession.decision(session).action == :request_budget_approval
    refute Map.has_key?(ObjectiveSession.decision(session), :next_objective)

    summary = ObjectiveSession.summary(session)
    assert summary.latest_error_kind == :timeout
    assert summary.latest_error_message == "RLM runtime budget exhausted"
    assert summary.latest_error.message == "RLM runtime budget exhausted"
  end

  test "budget approval after an error clears stale latest error state" do
    errored =
      ObjectiveSession.new!("Run long repair", id: "budget-error-clear")
      |> ObjectiveSession.record_error(
        Error.timeout("RLM runtime budget exhausted", details: %{stage: :repair})
      )

    assert errored.status == :needs_budget_approval
    assert errored.latest_error.kind == :timeout

    [%{resume_key: resume_key}] = errored.budget_requests
    decision = ReviewDecision.new!(resume_key, :approved, metadata: %{additional_iterations: 1})

    assert {:ok, resumed} = ObjectiveSession.record_budget_decision(errored, decision)

    assert resumed.status == :planning
    assert resumed.latest_error == nil
    assert ObjectiveSession.decision(resumed).action == :continue
  end

  test "review requests pause the objective loop for operator approval" do
    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:opslogic:plan",
        options: [:approve, :reject, :edit, :cancel],
        details: %{path: "tmp/ops_logic/PLAN.md"}
      )

    runner = fn _workspace, objective, opts ->
      assert objective == "Plan OpsLogic"
      assert Keyword.fetch!(opts, :objective_iteration) == 1

      {:ok,
       %{
         objective_scorecard: %{objective_status: :objective_satisfied},
         review_request: review_request,
         context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
       }}
    end

    assert {:ok, result} =
             ObjectiveLoop.run(:workspace, "Plan OpsLogic",
               runner: runner,
               max_iterations: 3
             )

    assert result.session.status == :needs_review_approval
    assert result.decision.action == :request_review_approval
    assert result.decision.request.resume_key == "review:opslogic:plan"

    assert {:ok, restored} =
             result.session |> ObjectiveSession.to_map() |> ObjectiveSession.from_map()

    assert restored.status == :needs_review_approval
    assert restored.review_requests == result.session.review_requests
    assert restored.iterations == result.session.iterations

    assert result.session.open_tasks == [
             %{
               id: "review:opslogic:plan",
               title: "objective_plan_approval approval required at plan_review",
               status: :review,
               target: :plan_review,
               metadata: %{}
             }
           ]

    assert ObjectiveSession.terminal?(result.session)
  end

  test "review approval closes the review task without dropping planned objective work" do
    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:opslogic:preserve-tasks",
        options: [:approve, :reject, :edit, :cancel],
        details: %{path: "tmp/ops_logic/PLAN.md"}
      )

    paused =
      ObjectiveSession.new!("Plan and implement OpsLogic")
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_satisfied},
        review_request: review_request,
        task_updates: [
          %{id: "plan", title: "Write implementation plan", status: :completed},
          %{id: "implementation", title: "Implement approved plan", status: :planned}
        ]
      })

    assert paused.status == :needs_review_approval
    assert Enum.any?(paused.open_tasks, &(&1.id == "review:opslogic:preserve-tasks"))
    assert Enum.any?(paused.open_tasks, &(&1.id == "implementation"))

    approved = ReviewDecision.new!("review:opslogic:preserve-tasks", :approved)

    assert {:ok, resumed} = ObjectiveSession.record_review_decision(paused, approved)

    assert resumed.status == :planning
    refute Enum.any?(resumed.open_tasks, &(&1.id == "review:opslogic:preserve-tasks"))

    assert [
             %{
               id: "implementation",
               title: "Implement approved plan",
               status: :planned
             }
           ] = resumed.open_tasks

    assert Enum.any?(resumed.completed_tasks, &(&1.id == "plan"))
  end

  test "blank edited operator decisions fall back to default continuation objectives" do
    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:opslogic:blank-edit",
        details: %{path: "tmp/ops_logic/PLAN.md"}
      )

    paused_for_review =
      ObjectiveSession.new!("Plan and implement OpsLogic")
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_satisfied},
        review_request: review_request,
        context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
      })

    review_decision =
      ReviewDecision.new!("review:opslogic:blank-edit", :edited, edited_value: "   ")

    assert {:ok, resumed_review} =
             ObjectiveSession.record_review_decision(paused_for_review, review_decision)

    assert resumed_review.status == :planning
    assert resumed_review.next_objective =~ "Continue the objective after operator approval"
    assert resumed_review.next_objective =~ "Plan and implement OpsLogic"

    paused_for_budget =
      ObjectiveSession.new!("Implement OpsLogic", id: "blank-budget-edit", max_iterations: 1)
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_incomplete},
        context: %{repair_needs: [%{id: "compile", reason: "compile still fails"}]}
      })

    budget_decision =
      ReviewDecision.new!("budget:blank-budget-edit:1", :edited, edited_value: " ")

    assert {:ok, resumed_budget} =
             ObjectiveSession.record_budget_decision(paused_for_budget, budget_decision)

    assert resumed_budget.status == :planning

    assert resumed_budget.next_objective =~
             "Continue the objective after operator budget approval"

    assert resumed_budget.next_objective =~ "Implement OpsLogic"
  end

  test "blank persisted or override next objectives fall back to objective text" do
    now = DateTime.utc_now()

    restored =
      %{
        id: "objective:blank-next",
        objective: "Implement OpsLogic",
        status: "planning",
        next_objective: "   ",
        created_at: now,
        updated_at: now,
        max_iterations: 2,
        iterations: [],
        progress_log: [],
        completed_tasks: [],
        open_tasks: [],
        review_requests: [],
        budget_requests: [],
        metadata: %{}
      }
      |> ObjectiveSession.from_map!()

    assert restored.next_objective == nil
    assert ObjectiveSession.next_workflow_objective(restored) == "Implement OpsLogic"

    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:opslogic:blank-next",
        details: %{path: "tmp/ops_logic/PLAN.md"}
      )

    paused =
      ObjectiveSession.new!("Plan and implement OpsLogic")
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_satisfied},
        review_request: review_request,
        context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
      })

    approved = ReviewDecision.new!("review:opslogic:blank-next", :approved)

    assert {:ok, resumed} =
             ObjectiveSession.record_review_decision(paused, approved, next_objective: " ")

    assert resumed.next_objective =~ "Continue the objective after operator approval"
    assert resumed.next_objective =~ "Plan and implement OpsLogic"
  end

  test "objective sessions accept JSON-style operator decision maps" do
    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:opslogic:string-decision",
        details: %{path: "tmp/ops_logic/PLAN.md"}
      )

    paused_for_review =
      ObjectiveSession.new!("Plan OpsLogic")
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_satisfied},
        review_request: review_request,
        context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
      })

    assert {:ok, approved_review} =
             ObjectiveSession.record_review_decision(paused_for_review, %{
               "resume_key" => "review:opslogic:string-decision",
               "status" => "approved",
               "actor" => "browser",
               "metadata" => %{"client" => "web"}
             })

    assert approved_review.status == :planning

    assert [
             %{
               status: :approved,
               decision: %{status: :approved, actor: "browser", metadata: %{"client" => "web"}}
             }
           ] = approved_review.review_requests

    paused_for_budget =
      ObjectiveSession.new!("Implement OpsLogic", id: "string-budget-decision", max_iterations: 1)
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_incomplete},
        context: %{repair_needs: [%{id: "compile", reason: "compile still fails"}]}
      })

    assert {:ok, approved_budget} =
             ObjectiveSession.record_budget_decision(paused_for_budget, %{
               "resume_key" => "budget:string-budget-decision:1",
               "status" => "approved",
               "metadata" => %{"additional_iterations" => 2}
             })

    assert approved_budget.status == :planning
    assert approved_budget.max_iterations == 3

    assert [%{status: :approved, decision: %{status: :approved}}] =
             approved_budget.budget_requests
  end

  test "review approval replaces stale JSON-loaded request lifecycle fields" do
    now = DateTime.utc_now()

    restored =
      %{
        id: "objective:json-review",
        objective: "Plan OpsLogic",
        status: "needs_review_approval",
        created_at: now,
        updated_at: now,
        max_iterations: 2,
        iterations: [],
        progress_log: [],
        completed_tasks: [],
        open_tasks: [],
        review_requests: [
          %{
            "kind" => "objective_plan_approval",
            "checkpoint" => "plan_review",
            "resume_key" => "review:json-plan",
            "status" => "pending"
          }
        ],
        budget_requests: [],
        metadata: %{}
      }
      |> ObjectiveSession.from_map!()

    decision = ReviewDecision.new!("review:json-plan", :approved)

    assert {:ok, approved} = ObjectiveSession.record_review_decision(restored, decision)
    assert ObjectiveSession.summary(approved).pending_review_request_count == 0

    assert [
             %{
               status: :approved,
               resolved_at: %DateTime{},
               decision: %{status: :approved}
             } = request
           ] = approved.review_requests

    refute Map.has_key?(request, "status")
    refute Map.has_key?(request, "decision")
    refute Map.has_key?(request, "resolved_at")

    serialized = ObjectiveSession.to_map(approved)

    assert [%{status: :approved}] = serialized.review_requests
    assert {:ok, reloaded} = ObjectiveSession.from_map(serialized)
    assert ObjectiveSession.summary(reloaded).pending_review_request_count == 0
  end

  test "budget approval replaces stale JSON-loaded request lifecycle fields" do
    now = DateTime.utc_now()

    restored =
      %{
        id: "objective:json-budget",
        objective: "Build OpsLogic",
        status: "needs_budget_approval",
        created_at: now,
        updated_at: now,
        max_iterations: 2,
        iterations: [%{"iteration" => 1}, %{"iteration" => 2}],
        progress_log: [],
        completed_tasks: [],
        open_tasks: [%{"id" => "implementation"}],
        review_requests: [],
        budget_requests: [
          %{
            "id" => "budget:json:2",
            "resume_key" => "budget:json:2",
            "reason" => "repair budget exhausted",
            "status" => "pending"
          }
        ],
        metadata: %{}
      }
      |> ObjectiveSession.from_map!()

    decision = ReviewDecision.new!("budget:json:2", :approved)

    assert {:ok, approved} =
             ObjectiveSession.record_budget_decision(restored, decision, additional_iterations: 1)

    assert approved.max_iterations == 3
    assert ObjectiveSession.summary(approved).pending_budget_request_count == 0

    assert [
             %{
               status: :approved,
               resolved_at: %DateTime{},
               decision: %{status: :approved}
             } = request
           ] = approved.budget_requests

    refute Map.has_key?(request, "status")
    refute Map.has_key?(request, "decision")
    refute Map.has_key?(request, "resolved_at")

    serialized = ObjectiveSession.to_map(approved)

    assert [%{status: :approved}] = serialized.budget_requests
    assert {:ok, reloaded} = ObjectiveSession.from_map(serialized)
    assert ObjectiveSession.summary(reloaded).pending_budget_request_count == 0
  end

  test "objective loop resumes the same session after review approval" do
    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:opslogic:resume",
        details: %{path: "tmp/ops_logic/PLAN.md"}
      )

    plan_runner = fn _workspace, _objective, opts ->
      assert Keyword.fetch!(opts, :objective_iteration) == 1

      {:ok,
       %{
         objective_scorecard: %{objective_status: :objective_satisfied},
         review_request: review_request,
         context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
       }}
    end

    assert {:ok, paused} =
             ObjectiveLoop.run(:workspace, "Plan and implement OpsLogic",
               runner: plan_runner,
               max_iterations: 3
             )

    assert paused.decision.action == :request_review_approval
    approved = ReviewDecision.new!("review:opslogic:resume", :approved)

    implementation_runner = fn _workspace, objective, opts ->
      assert Keyword.fetch!(opts, :objective_iteration) == 2
      assert objective =~ "Continue the objective after operator approval"
      assert objective =~ "Plan and implement OpsLogic"

      {:ok,
       %{
         objective_scorecard: %{objective_status: :objective_satisfied},
         context: %{changed_files: ["tmp/ops_logic/mix.exs"]}
       }}
    end

    assert {:ok, resumed} =
             ObjectiveLoop.resume_after_review(:workspace, paused.session, approved,
               runner: implementation_runner
             )

    assert resumed.decision.action == :complete
    assert resumed.session.status == :objective_satisfied
    assert length(resumed.session.iterations) == 2

    assert [
             %{
               status: :approved,
               resolved_at: %DateTime{},
               decision: %{status: :approved}
             }
           ] = resumed.session.review_requests

    assert ObjectiveSession.summary(resumed.session).pending_review_request_count == 0
    assert Enum.any?(resumed.session.progress_log, &(&1.event == :review_completed))
  end

  test "objective loop blocks without another workflow after review rejection" do
    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:opslogic:reject",
        details: %{path: "tmp/ops_logic/PLAN.md"}
      )

    paused =
      ObjectiveSession.new!("Plan and implement OpsLogic")
      |> ObjectiveSession.iteration_started()
      |> ObjectiveSession.record_result(%{
        objective_scorecard: %{objective_status: :objective_satisfied},
        review_request: review_request,
        context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
      })

    rejected = ReviewDecision.new!("review:opslogic:reject", :rejected)

    assert {:ok, resumed} =
             ObjectiveLoop.resume_after_review(:workspace, paused, rejected,
               runner: fn _workspace, _objective, _opts ->
                 flunk("rejected review decisions must not start another workflow")
               end
             )

    assert resumed.decision.action == :stop_blocked
    assert resumed.session.status == :blocked
    assert length(resumed.session.iterations) == 1

    assert [
             %{
               resume_key: "review:opslogic:reject",
               status: :rejected,
               resolved_at: %DateTime{},
               decision: %{status: :rejected}
             }
           ] = resumed.session.review_requests

    assert ObjectiveSession.summary(resumed.session).pending_review_request_count == 0
    assert Enum.any?(resumed.session.progress_log, &(&1.event == :review_completed))
  end

  test "objective loop blocks without expanding budget after budget cancellation" do
    runner = fn _workspace, _objective, opts ->
      assert Keyword.fetch!(opts, :objective_iteration) == 1

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
    end

    assert {:ok, paused} =
             ObjectiveLoop.run(:workspace, "Implement OpsLogic",
               runner: runner,
               max_iterations: 1
             )

    assert paused.decision.action == :request_budget_approval
    [%{resume_key: budget_resume_key}] = paused.session.budget_requests
    cancelled = ReviewDecision.new!(budget_resume_key, :cancelled)

    assert {:ok, resumed} =
             ObjectiveLoop.resume_after_budget(:workspace, paused.session, cancelled,
               runner: fn _workspace, _objective, _opts ->
                 flunk("cancelled budget decisions must not start another workflow")
               end
             )

    assert resumed.decision.action == :stop_blocked
    assert resumed.session.status == :blocked
    assert resumed.session.max_iterations == 1
    assert length(resumed.session.iterations) == 1

    assert [
             %{
               resume_key: ^budget_resume_key,
               status: :cancelled,
               resolved_at: %DateTime{},
               decision: %{status: :cancelled}
             }
           ] = resumed.session.budget_requests

    assert ObjectiveSession.summary(resumed.session).pending_budget_request_count == 0
    assert Enum.any?(resumed.session.progress_log, &(&1.event == :budget_completed))
  end

  test "objective loop supports OpsLogic plan review then implementation follow-up" do
    root = tmp_dir!("opslogic-two-turn")
    workspace = Workspace.new!(root: root)

    plan_prompt = opslogic_plan_prompt()

    plan_runner = fn ^workspace, ^plan_prompt, opts ->
      assert Keyword.fetch!(opts, :objective_iteration) == 1

      patch_set =
        EditPatchSet.new!(
          "Write OpsLogic implementation plan",
          [
            EditOperation.new!(:create_file,
              params: %{path: "tmp/ops_logic/PLAN.md", content: opslogic_plan(), overwrite: true}
            )
          ],
          expected_changed_files: ["tmp/ops_logic/PLAN.md"]
        )

      assert {:ok, output} = EditPatchSet.apply(workspace, patch_set)
      assert output.status == :ok

      {:ok,
       %{
         objective_scorecard: %{
           objective_status: :objective_satisfied,
           changed_files: output.changed_paths
         },
         context: %{changed_files: output.changed_paths}
       }}
    end

    assert {:ok, plan_result} =
             ObjectiveLoop.run(workspace, plan_prompt,
               runner: plan_runner,
               max_iterations: 2
             )

    assert plan_result.decision.action == :complete
    assert File.read!(Path.join(root, "tmp/ops_logic/PLAN.md")) =~ "OpsLogic"
    assert File.read!(Path.join(root, "tmp/ops_logic/PLAN.md")) =~ "Phoenix LiveView"

    implementation_objective = opslogic_implementation_objective()

    implementation_runner = fn ^workspace, objective, opts ->
      assert objective == implementation_objective
      assert Keyword.fetch!(opts, :objective_iteration) == 1
      assert File.read!(Path.join(root, "tmp/ops_logic/PLAN.md")) =~ "domain interface"

      patch_set = ElixirProjectGenerator.patch_set(objective)
      assert {:ok, output} = EditPatchSet.apply(workspace, patch_set)
      assert output.status == :ok

      checks = DeterministicChecks.evaluate(opslogic_scenario(objective), root)

      assert checks.status == :pass,
             inspect(Enum.filter(checks.checks, &(&1.status != :pass)), pretty: true)

      {:ok,
       %{
         objective_scorecard: %{
           objective_status: :objective_satisfied,
           changed_files: output.changed_paths
         },
         context: %{changed_files: output.changed_paths, deterministic_checks: checks}
       }}
    end

    assert {:ok, implementation_result} =
             ObjectiveLoop.run(workspace, implementation_objective,
               runner: implementation_runner,
               max_iterations: 2,
               metadata: %{plan_path: "tmp/ops_logic/PLAN.md"}
             )

    assert implementation_result.decision.action == :complete
    assert implementation_result.session.status == :objective_satisfied
    assert length(implementation_result.session.iterations) == 1
    assert File.exists?(Path.join(root, "tmp/ops_logic/mix.exs"))

    assert File.read!(Path.join(root, "tmp/ops_logic/lib/ops_logic/work_orders.ex")) =~
             "DynamicSupervisor"
  end

  defp tmp_dir!(name) do
    root =
      Path.join([
        System.tmp_dir!(),
        "runic-ai-#{name}-#{System.unique_integer([:positive])}"
      ])

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp opslogic_plan_prompt do
    """
    Write an implementation plan for a field service application using Elixir,
    Phoenix, and LiveView. Call the app "OpsLogic" (ops_logic) and build it in
    ./tmp/ops_logic. Present the plan for review before implementation.
    """
    |> String.trim()
  end

  defp opslogic_implementation_objective do
    """
    Now implement this implementation plan as described.

    Plan path: ./tmp/ops_logic/PLAN.md
    App: OpsLogic (ops_logic)
    Requirements: field service dispatch, customers, workers, work orders,
    worker lifecycle transitions, dynamically supervised GenServer runtime,
    functional state-machine core, domain interface, webhook integration API,
    Phoenix LiveView dispatcher and worker UI contracts, Postgres persistence
    schema, webhook routes, tests, compile evidence, and runtime smoke evidence.
    """
    |> String.trim()
  end

  defp opslogic_plan do
    """
    # OpsLogic Implementation Plan

    Build `ops_logic` in `./tmp/ops_logic` as an Elixir/Phoenix LiveView field
    service application. The durable architecture is organized around DDD
    contexts for customers, workers, scheduling, work orders, and webhooks.

    - Create a domain interface for customers, workers, and work orders.
    - Model work order lifecycle transitions as a functional core.
    - Host scheduled work orders in dynamically supervised GenServers.
    - Store customer and work order references in Postgres-backed contexts.
    - Add LiveView dispatcher and worker flows for scheduling, travel, arrival,
      work start, and completion.
    - Add webhook API events for integration consumers.
    - Verify with compile, tests, and runtime smoke evidence.
    """
  end

  defp opslogic_scenario(objective) do
    ProjectScenario.new!(
      id: "opslogic_two_turn_plan_implementation",
      title: "OpsLogic two-turn plan and implementation",
      prompt: objective,
      lanes: [:rlm],
      deterministic_checks: [
        %{type: :file_exists, path: "tmp/ops_logic/PLAN.md"},
        %{type: :file_exists, path: "tmp/ops_logic/mix.exs"},
        %{type: :file_exists, path: "tmp/ops_logic/config/test.exs"},
        %{
          type: :source_contains,
          path: "tmp/ops_logic/mix.exs",
          text: "phoenix_live_view"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/mix.exs",
          text: "ecto_sql"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/mix.exs",
          text: "postgrex"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/mix.exs",
          text: "bandit"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/mix.exs",
          text: "lazy_html"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/repo.ex",
          text: "use Ecto.Repo"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/work_orders/scheduled_work_order.ex",
          text: "use Ecto.Schema"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic_web/endpoint.ex",
          text: "use Phoenix.Endpoint"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/application.ex",
          text: "OpsLogicWeb.Endpoint"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/work_orders.ex",
          text: "DynamicSupervisor"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/work_orders.ex",
          text: "Ecto.Multi"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/work_orders.ex",
          text: "persisted_state"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/work_orders.ex",
          text: "apply_worker_action"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/mix/tasks/ops_logic.db_smoke.ex",
          text: "opslogic_db_smoke_pass"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/mix/tasks/ops_logic.browser_smoke.ex",
          text: "opslogic_browser_smoke_pass"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/priv/browser_smoke_runner.js",
          text: "OpsLogic Worker"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/work_order_server.ex",
          text: "GenServer"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/webhooks.ex",
          text: "work_order.completed"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic/persistence.ex",
          text: "repo_boundary"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic_web.ex",
          text: "use Phoenix.Router"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic_web/router.ex",
          text: "use OpsLogicWeb, :router"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic_web/router.ex",
          text: "live \"/dispatch\""
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic_web/dispatcher_live.ex",
          text: "schedule_work_order"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic_web/dispatcher_live.ex",
          text: "dispatch_schedule"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic_web/worker_live.ex",
          text: "initiate_travel"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic_web/worker_live.ex",
          text: "apply_worker_event"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/lib/ops_logic_web/worker_live.ex",
          text: "assigned_work_orders"
        },
        %{
          type: :source_contains,
          path: "tmp/ops_logic/test/ops_logic_web/live/ops_logic_live_test.exs",
          text: "live_isolated"
        },
        %{
          type: :source_contains,
          glob: "tmp/ops_logic/priv/repo/migrations/*.sql",
          text: "CREATE TABLE scheduled_work_orders"
        },
        %{
          type: :source_not_contains,
          glob: "tmp/ops_logic/test/**/*_test.exs",
          text: "greets the world"
        },
        %{
          type: :command_passes,
          argv: [
            "sh",
            "-c",
            "cd tmp/ops_logic && mix deps.get && mix compile --warnings-as-errors"
          ]
        },
        %{type: :command_passes, argv: ["sh", "-c", "cd tmp/ops_logic && mix test"]},
        %{
          type: :command_passes,
          argv: [
            "sh",
            "-c",
            "cd tmp/ops_logic && mix run -e 'IO.inspect(OpsLogic.runtime_smoke())'"
          ]
        },
        %{
          type: :command_passes_if_env,
          env: "RUN_OPSLOGIC_POSTGRES_SMOKE",
          argv: ["sh", "-c", "cd tmp/ops_logic && mix ops_logic.db_smoke"]
        },
        %{
          type: :command_passes_if_env,
          env: "RUN_OPSLOGIC_BROWSER_SMOKE",
          argv: ["sh", "-c", "cd tmp/ops_logic && mix ops_logic.browser_smoke"]
        }
      ],
      judge_rubric: %{},
      browser_user_story: "Review the generated OpsLogic plan and implementation evidence.",
      browser_validation_tasks: [],
      metadata: %{domain: :field_service, two_turn_plan?: true}
    )
  end
end
