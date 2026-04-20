defmodule RunicAI.Recipes.PlannerExecutorWorkflow do
  @moduledoc """
  Reference parent workflow that plans child tasks, materializes assignments,
  executes them, and reduces the results with a typed join policy.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Decomposition.Assignment
  alias RunicAI.Decomposition.Result
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.Recipes.ConversationalToolAgent
  alias RunicAI.Steps.BuildChildAssignments
  alias RunicAI.Steps.ExecuteChildAssignments
  alias RunicAI.Steps.PlanChildTasks
  alias RunicAI.Steps.ReduceChildResults

  @spec new(keyword()) :: Workflow.t()
  def new(opts \\ []) do
    input_step =
      Runic.step(
        fn input -> input end,
        name: :planner_executor_input
      )

    plan_step =
      PlanChildTasks.new(
        name: :plan_child_tasks,
        planner: Keyword.get(opts, :planner),
        tasks: Keyword.get(opts, :tasks),
        groups: Keyword.get(opts, :groups),
        join_policy: Keyword.get(opts, :join_policy),
        metadata: Keyword.get(opts, :metadata, %{})
      )

    build_input_step =
      Runic.step(
        fn %TaskPlan{} = task_plan, parent_input ->
          Map.put(parent_input, :task_plan, task_plan)
        end,
        name: :build_child_assignments_input
      )

    build_assignments_step =
      BuildChildAssignments.new(
        name: :build_child_assignments,
        registry: Keyword.get(opts, :registry),
        state: Keyword.get(opts, :state),
        inheritance_policy: Keyword.get(opts, :inheritance_policy),
        tool_registry: Keyword.get(opts, :tool_registry),
        selection: Keyword.get(opts, :selection),
        visible_tools: Keyword.get(opts, :visible_tools),
        budget_policy: Keyword.get(opts, :budget_policy),
        window_policy: Keyword.get(opts, :window_policy)
      )

    execute_input_step =
      ExecuteChildAssignments.input_step(name: :execute_child_assignments_input)

    execute_step = ExecuteChildAssignments.new(name: :execute_child_assignments)
    reduce_input_step = ReduceChildResults.input_step(name: :reduce_child_results_input)
    reduce_step = ReduceChildResults.new(name: :reduce_child_results)

    Workflow.new(name: Keyword.get(opts, :name, :planner_executor_workflow))
    |> Workflow.add(input_step)
    |> Workflow.add(plan_step, to: :planner_executor_input)
    |> Workflow.add(build_input_step, to: [:plan_child_tasks, :planner_executor_input])
    |> Workflow.add(build_assignments_step, to: :build_child_assignments_input)
    |> Workflow.add(execute_input_step, to: [:plan_child_tasks, :build_child_assignments])
    |> Workflow.add(execute_step, to: :execute_child_assignments_input)
    |> Workflow.add(reduce_input_step, to: [:plan_child_tasks, :execute_child_assignments])
    |> Workflow.add(reduce_step, to: :reduce_child_results_input)
  end

  @spec react_until_resolution(keyword(), map(), keyword()) :: Workflow.t()
  def react_until_resolution(opts, input, react_opts \\ [])
      when is_list(opts) and is_map(input) do
    new(opts)
    |> Workflow.react_until_satisfied(input, react_opts)
  end

  @spec initial_state(keyword()) :: RunicAI.Agent.State.t()
  def initial_state(opts \\ []), do: ConversationalToolAgent.initial_state(opts)

  @spec latest_task_plan(Workflow.t()) :: TaskPlan.t() | nil
  def latest_task_plan(%Workflow{} = workflow),
    do: latest_step_output(workflow, :plan_child_tasks)

  @spec latest_assignments(Workflow.t()) :: [Assignment.t()] | nil
  def latest_assignments(%Workflow{} = workflow),
    do: latest_step_output(workflow, :build_child_assignments)

  @spec latest_child_results(Workflow.t()) :: [Result.t()] | nil
  def latest_child_results(%Workflow{} = workflow),
    do: latest_step_output(workflow, :execute_child_assignments)

  @spec latest_result(Workflow.t()) :: Result.t() | nil
  def latest_result(%Workflow{} = workflow),
    do: latest_step_output(workflow, :reduce_child_results)

  @spec latest_output(Workflow.t()) :: term() | nil
  def latest_output(%Workflow{} = workflow) do
    case latest_result(workflow) do
      %Result{} = result -> result.output
      _ -> nil
    end
  end

  defp latest_step_output(%Workflow{} = workflow, step_name) do
    workflow
    |> Workflow.raw_productions(step_name)
    |> List.last()
  end
end
