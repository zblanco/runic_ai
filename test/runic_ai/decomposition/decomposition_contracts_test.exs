defmodule RunicAI.Decomposition.DecompositionContractsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Decomposition.Assignment
  alias RunicAI.Decomposition.Evaluation
  alias RunicAI.Decomposition.InheritancePolicy
  alias RunicAI.Decomposition.JoinPolicy
  alias RunicAI.Decomposition.Registry
  alias RunicAI.Decomposition.Result
  alias RunicAI.Decomposition.Role
  alias RunicAI.Decomposition.Task
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.ReviewRequest

  test "role registries keep reusable delegate profiles validated and fetchable" do
    role =
      Role.new!(
        name: "researcher",
        kind: :workflow,
        description: "Collect evidence for one scoped topic",
        builder: &__MODULE__.echo_builder/1,
        defaults: %{},
        accepts: [:research]
      )

    registry = Registry.new!([role])

    assert Registry.fetch!(registry, "researcher").description =~ "Collect evidence"
    assert Role.accepts?(role, :research)

    assert InheritancePolicy.new!(context_mode: :bundle, tool_mode: :subset).context_mode ==
             :bundle

    assert JoinPolicy.new!(mode: :quorum, quorum: 2).quorum == 2

    assert JoinPolicy.new!(mode: :merge, merge_conflicts: :nest_by_task).merge_conflicts ==
             :nest_by_task
  end

  test "task plans and assignments keep task intent separate from runtime invocation" do
    role =
      Role.new!(
        name: "critic",
        kind: :llm,
        description: "Score one candidate response",
        builder: &__MODULE__.echo_builder/1,
        defaults: %{}
      )

    task =
      Task.new!(
        id: "judge:candidate_1",
        goal: "Evaluate candidate_1",
        role: role,
        input: %{subject_id: "candidate_1"},
        depends_on: ["draft:candidate_1"],
        metadata: %{lane: :judge}
      )

    task_plan =
      TaskPlan.new!(
        [task],
        groups: [["judge:candidate_1"]],
        join_policy: [mode: :all_settled, on_partial_failure: :ignore]
      )

    assignment =
      Assignment.new!(
        task,
        role,
        inheritance: InheritancePolicy.new!(context_mode: :none),
        input: %{subject_id: "candidate_1"},
        resume_key: "child:judge:candidate_1"
      )

    assert TaskPlan.task_ids(task_plan) == ["judge:candidate_1"]
    assert assignment.task.id == "judge:candidate_1"
    assert assignment.role.name == "critic"
    assert assignment.resume_key == "child:judge:candidate_1"
  end

  test "results and evaluations normalize from public maps" do
    review_request =
      ReviewRequest.new!(
        :child_review,
        checkpoint: :candidate,
        resume_key: "review:candidate:1",
        subject: %{candidate_id: "candidate_1"}
      )

    result =
      Result.from_input!(%{
        "task_id" => "candidate_1",
        "status" => :review,
        "review_request" => review_request,
        "metadata" => %{"lane" => "jury"}
      })

    evaluation =
      Evaluation.from_input!(%{
        "subject_id" => "candidate_1",
        "judge" => "critic_a",
        "score" => 0.95,
        "reason" => "Most complete answer"
      })

    assert result.status == :review
    assert result.review_request.resume_key == "review:candidate:1"
    assert evaluation.subject_id == "candidate_1"
    assert evaluation.score == 0.95
  end

  def echo_builder(input), do: input
end
