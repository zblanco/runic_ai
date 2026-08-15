defmodule RunicAI.Recipes.ReviewerEditorJuryTest do
  use ExUnit.Case, async: true

  alias RunicAI.Decomposition.Role
  alias RunicAI.Decomposition.Task
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.Recipes.ReviewerEditorJury

  test "selects the highest-scoring candidate when judges agree" do
    workflow =
      ReviewerEditorJury.react_until_resolution(
        [registry: registry(), judge_roles: ["judge_a", "judge_b"]],
        %{task_plan: candidate_plan("good answer", "better answer")}
      )

    result = ReviewerEditorJury.latest_result(workflow)

    assert result.status == :completed
    assert result.output == "better answer"
    assert result.metadata.winner_task_id == "candidate:2"
    assert ReviewerEditorJury.latest_evaluations(workflow) |> length() == 4
  end

  test "falls back to review when the jury ties" do
    workflow =
      ReviewerEditorJury.react_until_resolution(
        [registry: tie_registry(), judge_roles: ["tie_judge"]],
        %{task_plan: candidate_plan("draft one", "draft two")}
      )

    result = ReviewerEditorJury.latest_result(workflow)

    assert result.status == :review
    assert result.review_request.kind == :jury_tie_break
  end

  defp candidate_plan(first, second) do
    TaskPlan.new!([
      Task.new!(
        id: "candidate:1",
        goal: "Draft candidate one",
        role: "writer",
        input: %{text: first}
      ),
      Task.new!(
        id: "candidate:2",
        goal: "Draft candidate two",
        role: "writer",
        input: %{text: second}
      )
    ])
  end

  defp registry do
    [
      writer_role(),
      judge_role("judge_a"),
      judge_role("judge_b")
    ]
  end

  defp tie_registry do
    [
      writer_role(),
      Role.new!(
        name: "tie_judge",
        kind: :workflow,
        description: "Assign the same score to every candidate",
        builder: &__MODULE__.tie_judge_builder/1,
        defaults: %{}
      )
    ]
  end

  defp writer_role do
    Role.new!(
      name: "writer",
      kind: :workflow,
      description: "Draft one candidate answer",
      builder: &__MODULE__.writer_builder/1,
      defaults: %{}
    )
  end

  defp judge_role(name) do
    Role.new!(
      name: name,
      kind: :workflow,
      description: "Score one candidate answer",
      builder: &__MODULE__.judge_builder/1,
      defaults: %{}
    )
  end

  def writer_builder(assignment) do
    assignment.input.input[:text]
  end

  def judge_builder(assignment) do
    subject_id = assignment.input.input[:subject_id]
    candidate_output = assignment.input.input[:candidate_output]
    score = if String.contains?(candidate_output, "better"), do: 0.95, else: 0.2

    %{
      subject_id: subject_id,
      judge: assignment.role.name,
      score: score,
      reason: "Scored by #{assignment.role.name}"
    }
  end

  def tie_judge_builder(assignment) do
    %{
      subject_id: assignment.input.input[:subject_id],
      judge: assignment.role.name,
      score: 0.5,
      reason: "Everything tied"
    }
  end
end
