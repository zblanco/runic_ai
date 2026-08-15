defmodule RunicAI.Recipes.PlannerExecutorWorkflowTest do
  use ExUnit.Case, async: true

  alias RunicAI.Decomposition.Role
  alias RunicAI.Decomposition.Task
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.Recipes.PlannerExecutorWorkflow

  test "plans child tasks, executes them, and merges the reduced output" do
    worker_role =
      Role.new!(
        name: "worker",
        kind: :workflow,
        description: "Produce one keyed payload",
        builder: &__MODULE__.worker_builder/1,
        defaults: %{}
      )

    task_plan =
      TaskPlan.new!(
        [
          Task.new!(
            id: "alpha",
            goal: "Produce alpha",
            role: "worker",
            input: %{key: "alpha", value: 1}
          ),
          Task.new!(
            id: "beta",
            goal: "Produce beta",
            role: "worker",
            input: %{key: "beta", value: 2}
          )
        ],
        join_policy: [mode: :merge]
      )

    workflow =
      PlannerExecutorWorkflow.react_until_resolution(
        [registry: [worker_role]],
        %{task_plan: task_plan}
      )

    assert PlannerExecutorWorkflow.latest_output(workflow) == %{"alpha" => 1, "beta" => 2}
    assert PlannerExecutorWorkflow.latest_assignments(workflow) |> length() == 2
  end

  def worker_builder(assignment) do
    payload = assignment.input.input
    %{(payload["key"] || payload[:key]) => payload["value"] || payload[:value]}
  end
end
