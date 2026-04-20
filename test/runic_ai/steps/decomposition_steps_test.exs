defmodule RunicAI.Steps.DecompositionStepsTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.State
  alias RunicAI.Context.Ref
  alias RunicAI.Context.State, as: ContextState
  alias RunicAI.Context.WindowPolicy
  alias RunicAI.Control.BudgetPolicy
  alias RunicAI.Decomposition.Assignment
  alias RunicAI.Decomposition.InheritancePolicy
  alias RunicAI.Decomposition.Registry, as: DecompositionRegistry
  alias RunicAI.Decomposition.Result
  alias RunicAI.Decomposition.Role
  alias RunicAI.Decomposition.Task
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.ReviewRequest
  alias RunicAI.Steps.BuildChildAssignments
  alias RunicAI.Steps.ExecuteChildAssignments
  alias RunicAI.Steps.JudgeCandidates
  alias RunicAI.Steps.ReduceChildResults
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry, as: ToolRegistry
  alias RunicAI.Wait

  test "build child assignments projects context, tools, and policy slices" do
    state =
      State.new!(system: "You are the parent")
      |> State.append_messages!([
        {:user, "Investigate the login failure."},
        {:assistant, "I'll trace the callback flow."},
        {:user, "Focus on the OAuth redirect mismatch."}
      ])
      |> State.with_context!(
        ContextState.new!(
          active_refs: [
            Ref.new!(:summary, "summary_1", label: "Recent auth summary"),
            Ref.new!(:artifact, "doc_1", label: "Callback guide")
          ]
        )
      )

    search_tool =
      Definition.new!(
        name: "search_docs",
        description: "Search documentation",
        parameter_schema: [],
        executor: fn _args -> {:ok, %{hits: []}} end
      )

    patch_tool =
      Definition.new!(
        name: "apply_patch",
        description: "Apply a code patch",
        parameter_schema: [],
        executor: fn _args -> {:ok, %{applied: true}} end
      )

    role =
      Role.new!(
        name: "researcher",
        kind: :workflow,
        description: "Collect evidence on one scoped issue",
        builder: &__MODULE__.echo_assignment/1,
        defaults: %{
          inheritance_policy:
            InheritancePolicy.new!(
              context_mode: :bundle,
              tool_mode: :subset,
              allowed_tools: ["search_docs"],
              budget_mode: :copy
            )
        }
      )

    task_plan =
      TaskPlan.new!([
        Task.new!(
          id: "research:oauth",
          goal: "Research the OAuth callback mismatch",
          role: "researcher"
        )
      ])

    [assignment] =
      BuildChildAssignments.build!(
        %{
          task_plan: task_plan,
          state: state,
          tool_registry: ToolRegistry.new!([search_tool, patch_tool]),
          visible_tools: ["search_docs", "apply_patch"]
        },
        registry: DecompositionRegistry.new!([role]),
        budget_policy: BudgetPolicy.new!(max_turns: 4),
        window_policy: WindowPolicy.new!(fresh_tail_messages: 4)
      )

    assert assignment.input.context_bundle != nil
    assert assignment.input.budget_policy.max_turns == 4
    assert assignment.input.window_policy.fresh_tail_messages == 4
    assert Enum.map(assignment.input.visible_tools, & &1.name) == ["search_docs"]
    assert assignment.seed_state != nil
    assert assignment.metadata.context_mode == :bundle
  end

  test "execute child assignments can run workflow-backed delegates" do
    role =
      Role.new!(
        name: "workflow_delegate",
        kind: :workflow,
        description: "Emit a workflow-derived payload",
        builder: &__MODULE__.workflow_builder/1,
        defaults: %{result_extractor: &__MODULE__.extract_workflow_output/1}
      )

    task = Task.new!(id: "workflow:1", goal: "Emit payload", role: role)

    assignment =
      Assignment.new!(
        task,
        role,
        inheritance: InheritancePolicy.new!(),
        input: %{payload: "hello"}
      )

    results = ExecuteChildAssignments.execute!(TaskPlan.new!([task]), [assignment])

    assert [%Result{status: :completed, output: %{payload: "hello"}}] = results
    assert hd(results).metadata.assignment_id == "assignment:workflow:1"
  end

  test "execute child assignments normalize control results and dependency cancellation" do
    fail_role =
      Role.new!(
        name: "failing_worker",
        kind: :workflow,
        description: "Always fails",
        builder: fn _assignment -> {:error, :boom} end,
        defaults: %{}
      )

    review_role =
      Role.new!(
        name: "review_worker",
        kind: :workflow,
        description: "Requests review",
        builder: fn assignment ->
          ReviewRequest.new!(
            :child_review,
            checkpoint: :delegate,
            resume_key: "review:#{assignment.task.id}",
            subject: assignment.task.goal
          )
        end,
        defaults: %{}
      )

    wait_role =
      Role.new!(
        name: "wait_worker",
        kind: :workflow,
        description: "Requests a wait",
        builder: fn assignment ->
          Wait.new!(:external_signal, resume_key: "wait:#{assignment.task.id}")
        end,
        defaults: %{}
      )

    fail_task = Task.new!(id: "task:fail", goal: "Fail", role: fail_role)
    review_task = Task.new!(id: "task:review", goal: "Review", role: review_role)
    wait_task = Task.new!(id: "task:wait", goal: "Wait", role: wait_role)

    blocked_task =
      Task.new!(id: "task:blocked", goal: "Blocked", role: review_role, depends_on: ["task:fail"])

    assignments = [
      Assignment.new!(fail_task, fail_role, inheritance: InheritancePolicy.new!(), input: %{}),
      Assignment.new!(review_task, review_role, inheritance: InheritancePolicy.new!(), input: %{}),
      Assignment.new!(wait_task, wait_role, inheritance: InheritancePolicy.new!(), input: %{}),
      Assignment.new!(blocked_task, review_role,
        inheritance: InheritancePolicy.new!(),
        input: %{}
      )
    ]

    results =
      ExecuteChildAssignments.execute!(
        TaskPlan.new!([fail_task, review_task, wait_task, blocked_task]),
        assignments
      )

    assert Enum.map(results, & &1.status) == [:failed, :review, :wait, :cancelled]
  end

  test "execute child assignments can normalize evaluation-like maps from task metadata" do
    judge_role =
      Role.new!(
        name: "judge_worker",
        kind: :workflow,
        description: "Returns an evaluation-shaped map",
        builder: fn _assignment -> %{score: 0.8, verdict: "pass", reason: "Looks good"} end,
        defaults: %{}
      )

    judge_task =
      Task.new!(
        id: "judge:candidate:1",
        goal: "Judge candidate one",
        role: judge_role,
        metadata: %{subject_id: "candidate:1", judge: "judge_worker"}
      )

    assignment =
      Assignment.new!(
        judge_task,
        judge_role,
        inheritance: InheritancePolicy.new!(),
        input: %{}
      )

    [result] = ExecuteChildAssignments.execute!(TaskPlan.new!([judge_task]), [assignment])

    assert result.status == :completed
    assert %RunicAI.Decomposition.Evaluation{} = result.output
    assert result.output.subject_id == "candidate:1"
    assert result.output.judge == "judge_worker"
  end

  test "reduce child results and judge candidates support score-based selection" do
    task_plan = TaskPlan.new!([], join_policy: [mode: :score, score_by: :score])

    results = [
      Result.completed!("candidate:a", %{subject_id: "candidate:a", score: 0.25}),
      Result.completed!("candidate:b", %{subject_id: "candidate:b", score: 0.9})
    ]

    reduced = ReduceChildResults.reduce!(task_plan, results)

    assert reduced.metadata.winner_task_id == "candidate:b"
    assert reduced.output == %{subject_id: "candidate:b", score: 0.9}

    judge_results = [
      Result.completed!("judge:candidate:a", %{score: 0.4},
        metadata: %{subject_id: "candidate:a", judge: "critic_a"}
      ),
      Result.completed!("judge:candidate:b", %{score: 0.8},
        metadata: %{subject_id: "candidate:b", judge: "critic_a"}
      )
    ]

    evaluations = JudgeCandidates.judge!(judge_results)

    assert Enum.find(evaluations, &(&1.subject_id == "candidate:b")).score == 0.8
  end

  test "merge joins fail on conflicting map keys by default" do
    task_plan = TaskPlan.new!([], join_policy: [mode: :merge])

    results = [
      Result.completed!("candidate:a", %{model: "openai", notes: "a"}),
      Result.completed!("candidate:b", %{model: "anthropic", notes: "b"})
    ]

    reduced = ReduceChildResults.reduce!(task_plan, results)

    assert reduced.status == :failed
    assert reduced.error.message =~ "conflicting keys"
  end

  test "merge joins can nest outputs by task id" do
    task_plan =
      TaskPlan.new!([], join_policy: [mode: :merge, merge_conflicts: :nest_by_task])

    results = [
      Result.completed!("candidate:a", %{model: "openai", notes: "a"}),
      Result.completed!("candidate:b", %{model: "anthropic", notes: "b"})
    ]

    reduced = ReduceChildResults.reduce!(task_plan, results)

    assert reduced.status == :completed

    assert reduced.output == %{
             "candidate:a" => %{model: "openai", notes: "a"},
             "candidate:b" => %{model: "anthropic", notes: "b"}
           }
  end

  test "merge joins can keep the first conflicting value" do
    task_plan =
      TaskPlan.new!([], join_policy: [mode: :merge, merge_conflicts: :first_wins])

    results = [
      Result.completed!("candidate:a", %{model: "openai", notes: "a"}),
      Result.completed!("candidate:b", %{model: "anthropic", extra: "b"})
    ]

    reduced = ReduceChildResults.reduce!(task_plan, results)

    assert reduced.status == :completed
    assert reduced.output.model == "openai"
    assert reduced.output.extra == "b"
  end

  test "merge joins can keep the last conflicting value" do
    task_plan =
      TaskPlan.new!([], join_policy: [mode: :merge, merge_conflicts: :last_wins])

    results = [
      Result.completed!("candidate:a", %{model: "openai", notes: "a"}),
      Result.completed!("candidate:b", %{model: "anthropic", extra: "b"})
    ]

    reduced = ReduceChildResults.reduce!(task_plan, results)

    assert reduced.status == :completed
    assert reduced.output.model == "anthropic"
    assert reduced.output.extra == "b"
  end

  def echo_assignment(assignment), do: assignment

  def workflow_builder(_assignment) do
    Workflow.new(name: :child_delegate)
    |> Workflow.add(
      Runic.step(
        fn input ->
          %{payload: Map.fetch!(input, :payload)}
        end,
        name: :emit_workflow_output
      )
    )
  end

  def extract_workflow_output(%{workflow: workflow}) do
    workflow
    |> Workflow.raw_productions(:emit_workflow_output)
    |> List.last()
  end
end
