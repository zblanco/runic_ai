defmodule RunicAI.Steps.ExecuteChildAssignments do
  @moduledoc """
  Execute materialized child assignments and normalize their outcomes.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Context.HandoffArtifact
  alias RunicAI.Decomposition.Assignment
  alias RunicAI.Decomposition.Callable
  alias RunicAI.Decomposition.Evaluation
  alias RunicAI.Decomposition.Result
  alias RunicAI.Decomposition.Role
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.Error
  alias RunicAI.ReviewRequest
  alias RunicAI.Wait

  @type input :: %{task_plan: TaskPlan.t(), assignments: [Assignment.t()]}

  def input_step(opts \\ []) do
    name = Keyword.get(opts, :name, :execute_child_assignments_input)

    Runic.step(
      fn %TaskPlan{} = task_plan, assignments ->
        bundle_input!(task_plan, assignments)
      end,
      name: name
    )
  end

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :execute_child_assignments)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn %{task_plan: %TaskPlan{} = task_plan, assignments: assignments} ->
        execute!(task_plan, assignments, defaults)
      end,
      name: name
    )
  end

  @spec bundle_input(TaskPlan.t(), [Assignment.t()]) :: {:ok, input()} | {:error, Error.t()}
  def bundle_input(%TaskPlan{} = task_plan, assignments) when is_list(assignments) do
    with {:ok, task_plan} <- TaskPlan.validate(task_plan),
         {:ok, assignments} <- normalize_assignments(assignments) do
      {:ok, %{task_plan: task_plan, assignments: assignments}}
    end
  end

  @spec bundle_input!(TaskPlan.t(), [Assignment.t()]) :: input()
  def bundle_input!(%TaskPlan{} = task_plan, assignments) do
    case bundle_input(task_plan, assignments) do
      {:ok, bundled_input} -> bundled_input
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec execute(TaskPlan.t(), [Assignment.t()], keyword()) ::
          {:ok, [Result.t()]} | {:error, Error.t()}
  def execute(%TaskPlan{} = task_plan, assignments, opts \\ []) when is_list(assignments) do
    with {:ok, task_plan} <- TaskPlan.validate(task_plan),
         {:ok, assignments} <- normalize_assignments(assignments),
         {:ok, stages} <- resolve_stages(task_plan, assignments) do
      {:ok, execute_stages(stages, [], opts)}
    end
  end

  @spec execute!(TaskPlan.t(), [Assignment.t()], keyword()) :: [Result.t()]
  def execute!(%TaskPlan{} = task_plan, assignments, opts \\ []) do
    case execute(task_plan, assignments, opts) do
      {:ok, results} -> results
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_assignments(assignments) do
    assignments
    |> Enum.reduce_while({:ok, []}, fn assignment, {:ok, acc} ->
      case Assignment.validate(assignment) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp resolve_stages(%TaskPlan{groups: nil}, assignments) do
    derive_stages_from_dependencies(assignments)
  end

  defp resolve_stages(%TaskPlan{groups: groups}, assignments) when is_list(groups) do
    explicit = Enum.map(groups, &resolve_group(&1, assignments))

    with {:ok, resolved_explicit} <- sequence(explicit),
         {:ok, implicit} <-
           derive_stages_from_dependencies(
             Enum.reject(assignments, fn assignment ->
               Enum.any?(resolved_explicit, &(assignment in &1))
             end)
           ) do
      {:ok, resolved_explicit ++ implicit}
    end
  end

  defp resolve_group(group, assignments) do
    group
    |> Enum.map(fn task_id ->
      Enum.find(assignments, &(&1.task.id == task_id)) ||
        raise ArgumentError, "unknown child task id in execution group: #{inspect(task_id)}"
    end)
    |> then(&{:ok, &1})
  end

  defp derive_stages_from_dependencies([]), do: {:ok, []}

  defp derive_stages_from_dependencies(assignments) do
    do_derive_stages(assignments, MapSet.new(), [])
  end

  defp do_derive_stages([], _completed, acc), do: {:ok, Enum.reverse(acc)}

  defp do_derive_stages(assignments, completed_ids, acc) do
    {ready, blocked} =
      Enum.split_with(assignments, fn %Assignment{} = assignment ->
        Enum.all?(assignment.task.depends_on, &MapSet.member?(completed_ids, &1))
      end)

    case ready do
      [] ->
        {:error,
         Error.validation("cyclic or unsatisfied child task dependencies",
           source: __MODULE__,
           details: %{remaining_task_ids: Enum.map(blocked, & &1.task.id)}
         )}

      _ ->
        next_completed =
          Enum.reduce(ready, completed_ids, fn assignment, acc_ids ->
            MapSet.put(acc_ids, assignment.task.id)
          end)

        do_derive_stages(blocked, next_completed, [ready | acc])
    end
  end

  defp execute_stages([], acc, _opts), do: acc

  defp execute_stages([stage | rest], acc, opts) do
    previous_results = Map.new(acc, &{&1.task_id, &1})

    {cancelled, runnable} =
      Enum.split_with(stage, fn %Assignment{} = assignment ->
        dependency_blocked?(assignment, previous_results)
      end)

    cancelled_results =
      Enum.map(cancelled, fn assignment ->
        Result.cancelled!(
          assignment.task.id,
          output: %{reason: :dependency_unmet, depends_on: assignment.task.depends_on},
          child_state: assignment.seed_state,
          metadata: result_metadata(assignment)
        )
      end)

    executed_results =
      case runnable do
        [] -> []
        [_single] -> execute_serial(runnable)
        _many -> execute_parallel(runnable)
      end

    stage_results =
      stage
      |> Enum.map(fn assignment ->
        Enum.find(cancelled_results ++ executed_results, &(&1.task_id == assignment.task.id))
      end)

    execute_stages(rest, acc ++ stage_results, opts)
  end

  defp dependency_blocked?(%Assignment{} = assignment, previous_results) do
    Enum.any?(assignment.task.depends_on, fn dependency_id ->
      case Map.get(previous_results, dependency_id) do
        %Result{status: :completed} -> false
        nil -> true
        _ -> true
      end
    end)
  end

  defp execute_serial(assignments) do
    Enum.map(assignments, &safe_execute_one/1)
  end

  defp execute_parallel([]), do: []

  defp execute_parallel(assignments) do
    map_name = :execute_child_assignment_parallel_map
    reduce_name = :execute_child_assignment_parallel_reduce

    workflow =
      Workflow.new(name: :execute_child_assignments_parallel_workflow)
      |> Workflow.add(
        Runic.map(
          fn %Assignment{} = assignment ->
            safe_execute_one(assignment)
          end,
          name: map_name
        )
      )
      |> Workflow.add(
        Runic.reduce(
          [],
          fn %Result{} = result, acc -> [result | acc] end,
          name: reduce_name,
          map: map_name
        ),
        to: map_name
      )
      |> Workflow.plan_eagerly(assignments)
      |> Workflow.react_until_satisfied()

    case Workflow.raw_productions(workflow, reduce_name) |> List.last() do
      results when is_list(results) ->
        ordered = Map.new(results, &{&1.task_id, &1})
        Enum.map(assignments, &Map.fetch!(ordered, &1.task.id))

      _ ->
        []
    end
  end

  defp safe_execute_one(%Assignment{} = assignment) do
    assignment
    |> execute_one()
    |> normalize_execution_result(assignment)
  rescue
    exception ->
      Result.failed!(
        assignment.task.id,
        Error.from_exception(exception, source: __MODULE__),
        child_state: assignment.seed_state,
        metadata: result_metadata(assignment)
      )
  catch
    kind, reason ->
      Result.failed!(
        assignment.task.id,
        Error.from_reason({kind, reason}, source: __MODULE__),
        child_state: assignment.seed_state,
        metadata: result_metadata(assignment)
      )
  end

  defp execute_one(%Assignment{role: %Role{} = role} = assignment) do
    role
    |> Role.invoke(assignment)
    |> maybe_run_child_workflow(assignment)
  end

  defp maybe_run_child_workflow(%Workflow{} = workflow, %Assignment{} = assignment) do
    reacted =
      Workflow.react_until_satisfied(
        workflow,
        assignment.input,
        role_react_opts(assignment.role)
      )

    extractor = role_result_extractor(assignment.role)

    case extractor do
      nil ->
        default_workflow_result(reacted)

      result_extractor ->
        Callable.invoke(result_extractor, %{
          workflow: reacted,
          assignment: assignment,
          role: assignment.role
        })
    end
  end

  defp maybe_run_child_workflow(other, _assignment), do: other

  defp role_react_opts(%Role{} = role) do
    Map.get(role.defaults, :react_opts) || Map.get(role.defaults, "react_opts") || []
  end

  defp role_result_extractor(%Role{} = role) do
    Map.get(role.defaults, :result_extractor) || Map.get(role.defaults, "result_extractor")
  end

  defp default_workflow_result(%Workflow{} = workflow) do
    Workflow.raw_productions(workflow) |> List.last()
  end

  defp normalize_execution_result(raw, %Assignment{} = assignment) do
    case normalize_child_result(raw, assignment) do
      {:ok, %Result{} = result} ->
        result

      {:error, error} ->
        Result.failed!(assignment.task.id, error, child_state: assignment.seed_state)
    end
  end

  defp normalize_child_result({:ok, value}, assignment),
    do: normalize_child_result(value, assignment)

  defp normalize_child_result({:error, %Error{} = error}, %Assignment{} = assignment) do
    {:ok,
     Result.failed!(
       assignment.task.id,
       error,
       child_state: assignment.seed_state,
       metadata: result_metadata(assignment)
     )}
  end

  defp normalize_child_result({:error, reason}, %Assignment{} = assignment) do
    normalize_child_result(Error.from_reason(reason, source: __MODULE__), assignment)
  end

  defp normalize_child_result(
         {:review, %ReviewRequest{} = review_request},
         %Assignment{} = assignment
       ) do
    {:ok,
     Result.review!(
       assignment.task.id,
       review_request,
       child_state: assignment.seed_state,
       metadata: result_metadata(assignment)
     )}
  end

  defp normalize_child_result({:wait, %Wait{} = wait}, %Assignment{} = assignment) do
    {:ok,
     Result.wait!(
       assignment.task.id,
       wait,
       child_state: assignment.seed_state,
       metadata: result_metadata(assignment)
     )}
  end

  defp normalize_child_result(
         {:handoff, %HandoffArtifact{} = handoff},
         %Assignment{} = assignment
       ) do
    {:ok,
     Result.handoff!(
       assignment.task.id,
       handoff,
       child_state: assignment.seed_state,
       metadata: result_metadata(assignment)
     )}
  end

  defp normalize_child_result({:completed, value}, %Assignment{} = assignment) do
    normalize_child_result(value, assignment)
  end

  defp normalize_child_result({:failed, reason}, %Assignment{} = assignment) do
    normalize_child_result({:error, reason}, assignment)
  end

  defp normalize_child_result({:cancelled, value}, %Assignment{} = assignment) do
    {:ok,
     Result.cancelled!(
       assignment.task.id,
       output: value,
       child_state: assignment.seed_state,
       metadata: result_metadata(assignment)
     )}
  end

  defp normalize_child_result(%Result{} = result, _assignment), do: Result.validate(result)

  defp normalize_child_result(%ReviewRequest{} = review_request, %Assignment{} = assignment) do
    normalize_child_result({:review, review_request}, assignment)
  end

  defp normalize_child_result(%Wait{} = wait, %Assignment{} = assignment) do
    normalize_child_result({:wait, wait}, assignment)
  end

  defp normalize_child_result(%HandoffArtifact{} = handoff, %Assignment{} = assignment) do
    normalize_child_result({:handoff, handoff}, assignment)
  end

  defp normalize_child_result(%Error{} = error, %Assignment{} = assignment) do
    normalize_child_result({:error, error}, assignment)
  end

  defp normalize_child_result(%Evaluation{} = evaluation, %Assignment{} = assignment) do
    {:ok,
     Result.completed!(
       assignment.task.id,
       evaluation,
       child_state: assignment.seed_state,
       metadata: result_metadata(assignment, %{evaluation: true})
     )}
  end

  defp normalize_child_result(raw_map, %Assignment{} = assignment) when is_map(raw_map) do
    cond do
      result_like_map?(raw_map) ->
        normalized_map =
          raw_map
          |> Map.new()
          |> Map.put_new(:task_id, assignment.task.id)
          |> Map.put_new(:metadata, %{})
          |> update_in([:metadata], fn metadata ->
            Map.merge(metadata || %{}, %{
              assignment_id: assignment.id,
              role: assignment.role.name
            })
          end)

        Result.from_input(normalized_map)

      evaluation_like_map?(raw_map) ->
        evaluation_input =
          raw_map
          |> Map.new()
          |> Map.put_new(
            :subject_id,
            metadata_value(assignment.task.metadata, :subject_id) || assignment.task.id
          )
          |> Map.put_new(
            :judge,
            metadata_value(assignment.task.metadata, :judge) || assignment.role.name
          )
          |> Map.put_new(:metadata, result_metadata(assignment))

        normalize_child_result(Evaluation.from_input!(evaluation_input), assignment)

      true ->
        {:ok,
         Result.completed!(
           assignment.task.id,
           raw_map,
           child_state: assignment.seed_state,
           metadata: result_metadata(assignment)
         )}
    end
  end

  defp normalize_child_result(other, %Assignment{} = assignment) do
    {:ok,
     Result.completed!(
       assignment.task.id,
       other,
       child_state: assignment.seed_state,
       metadata: result_metadata(assignment)
     )}
  end

  defp result_like_map?(value) when is_map(value) do
    Map.has_key?(value, :status) or Map.has_key?(value, "status")
  end

  defp evaluation_like_map?(value) when is_map(value) do
    Enum.any?(
      [:score, "score", :subject_id, "subject_id", :verdict, "verdict"],
      &Map.has_key?(value, &1)
    )
  end

  defp sequence(items) do
    Enum.reduce_while(items, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, error}, _acc -> {:halt, {:error, error}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp result_metadata(%Assignment{} = assignment, extra \\ %{}) do
    assignment.task.metadata
    |> Map.merge(assignment.metadata)
    |> Map.merge(%{
      assignment_id: assignment.id,
      role: assignment.role.name
    })
    |> Map.merge(extra)
  end

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end
end
