defmodule RunicAI.Recipes.ReviewerEditorJury do
  @moduledoc """
  Reference workflow that generates candidate outputs, evaluates them with one
  or more judge roles, and deterministically selects a winner or escalates to
  review.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Decomposition.Evaluation
  alias RunicAI.Decomposition.Result
  alias RunicAI.Decomposition.Task
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.ReviewRequest
  alias RunicAI.Steps.BuildChildAssignments
  alias RunicAI.Steps.ExecuteChildAssignments
  alias RunicAI.Steps.JudgeCandidates
  alias RunicAI.Steps.PlanChildTasks

  @spec new(keyword()) :: Workflow.t()
  def new(opts \\ []) do
    input_step =
      Runic.step(
        fn input -> input end,
        name: :reviewer_editor_jury_input
      )

    candidate_plan_step =
      PlanChildTasks.new(
        name: :plan_candidate_tasks,
        planner: Keyword.get(opts, :planner) || Keyword.get(opts, :candidate_planner),
        tasks: Keyword.get(opts, :tasks),
        groups: Keyword.get(opts, :groups),
        join_policy: Keyword.get(opts, :candidate_join_policy),
        metadata: %{lane: :candidates}
      )

    candidate_build_input_step =
      Runic.step(
        fn %TaskPlan{} = task_plan, input -> Map.put(input, :task_plan, task_plan) end,
        name: :candidate_build_input
      )

    candidate_build_step =
      BuildChildAssignments.new(
        name: :build_candidate_assignments,
        registry: Keyword.get(opts, :registry),
        state: Keyword.get(opts, :state),
        inheritance_policy: Keyword.get(opts, :inheritance_policy),
        tool_registry: Keyword.get(opts, :tool_registry),
        selection: Keyword.get(opts, :selection),
        visible_tools: Keyword.get(opts, :visible_tools),
        budget_policy: Keyword.get(opts, :budget_policy),
        window_policy: Keyword.get(opts, :window_policy)
      )

    candidate_execute_input_step =
      ExecuteChildAssignments.input_step(name: :execute_candidate_assignments_input)

    candidate_execute_step =
      ExecuteChildAssignments.new(name: :execute_candidate_assignments)

    judge_plan_step =
      Runic.step(
        fn candidate_results ->
          build_judge_task_plan!(candidate_results, opts)
        end,
        name: :plan_judge_tasks
      )

    judge_build_input_step =
      Runic.step(
        fn %TaskPlan{} = task_plan, input -> Map.put(input, :task_plan, task_plan) end,
        name: :judge_build_input
      )

    judge_build_step =
      BuildChildAssignments.new(
        name: :build_judge_assignments,
        registry: Keyword.get(opts, :registry),
        state: Keyword.get(opts, :state),
        inheritance_policy:
          Keyword.get(opts, :judge_inheritance_policy) || Keyword.get(opts, :inheritance_policy),
        tool_registry: Keyword.get(opts, :tool_registry),
        selection: Keyword.get(opts, :selection),
        visible_tools: Keyword.get(opts, :visible_tools),
        budget_policy: Keyword.get(opts, :budget_policy),
        window_policy: Keyword.get(opts, :window_policy)
      )

    judge_execute_input_step =
      ExecuteChildAssignments.input_step(name: :execute_judge_assignments_input)

    judge_execute_step =
      ExecuteChildAssignments.new(name: :execute_judge_assignments)

    judge_candidates_step =
      JudgeCandidates.new(
        name: :judge_candidates,
        extractor: Keyword.get(opts, :evaluation_extractor)
      )

    final_step =
      Runic.step(
        fn candidate_results, evaluations ->
          resolve_jury_result!(candidate_results, evaluations, opts)
        end,
        name: :resolve_jury_result
      )

    Workflow.new(name: Keyword.get(opts, :name, :reviewer_editor_jury))
    |> Workflow.add(input_step)
    |> Workflow.add(candidate_plan_step, to: :reviewer_editor_jury_input)
    |> Workflow.add(candidate_build_input_step,
      to: [:plan_candidate_tasks, :reviewer_editor_jury_input]
    )
    |> Workflow.add(candidate_build_step, to: :candidate_build_input)
    |> Workflow.add(candidate_execute_input_step,
      to: [:plan_candidate_tasks, :build_candidate_assignments]
    )
    |> Workflow.add(candidate_execute_step, to: :execute_candidate_assignments_input)
    |> Workflow.add(judge_plan_step, to: :execute_candidate_assignments)
    |> Workflow.add(judge_build_input_step, to: [:plan_judge_tasks, :reviewer_editor_jury_input])
    |> Workflow.add(judge_build_step, to: :judge_build_input)
    |> Workflow.add(judge_execute_input_step, to: [:plan_judge_tasks, :build_judge_assignments])
    |> Workflow.add(judge_execute_step, to: :execute_judge_assignments_input)
    |> Workflow.add(judge_candidates_step, to: :execute_judge_assignments)
    |> Workflow.add(final_step, to: [:execute_candidate_assignments, :judge_candidates])
  end

  @spec react_until_resolution(keyword(), map(), keyword()) :: Workflow.t()
  def react_until_resolution(opts, input, react_opts \\ [])
      when is_list(opts) and is_map(input) do
    new(opts)
    |> Workflow.react_until_satisfied(input, react_opts)
  end

  @spec latest_candidate_results(Workflow.t()) :: [Result.t()] | nil
  def latest_candidate_results(%Workflow{} = workflow),
    do: latest_step_output(workflow, :execute_candidate_assignments)

  @spec latest_evaluations(Workflow.t()) :: [Evaluation.t()] | nil
  def latest_evaluations(%Workflow{} = workflow),
    do: latest_step_output(workflow, :judge_candidates)

  @spec latest_result(Workflow.t()) :: Result.t() | nil
  def latest_result(%Workflow{} = workflow),
    do: latest_step_output(workflow, :resolve_jury_result)

  defp build_judge_task_plan!(candidate_results, opts) do
    judge_roles = normalize_judge_roles(opts)

    tasks =
      candidate_results
      |> normalize_results()
      |> Enum.filter(&(&1.status == :completed))
      |> Enum.flat_map(fn candidate ->
        Enum.map(judge_roles, fn judge_role ->
          role_ref = role_ref(judge_role)
          judge_name = role_name(judge_role)

          Task.new!(
            id: "judge:#{candidate.task_id}:#{judge_name}",
            goal: "Evaluate candidate #{candidate.task_id}",
            role: role_ref,
            instructions: Keyword.get(opts, :judge_instructions),
            input: %{
              subject_id: candidate.task_id,
              candidate_task_id: candidate.task_id,
              candidate_output: candidate.output,
              candidate_artifacts: candidate.artifacts,
              candidate_metadata: candidate.metadata
            },
            metadata: %{subject_id: candidate.task_id, judge: judge_name}
          )
        end)
      end)

    TaskPlan.new!(
      tasks,
      join_policy:
        Keyword.get(opts, :judge_join_policy, mode: :all_settled, on_partial_failure: :ignore),
      metadata: %{lane: :judges}
    )
  end

  defp resolve_jury_result!(candidate_results, evaluations, opts) do
    candidate_results = normalize_results(candidate_results)

    case Enum.find(candidate_results, &(&1.status in [:review, :wait, :handoff])) do
      %Result{} = control_result ->
        control_result

      nil ->
        completed_candidates = Enum.filter(candidate_results, &(&1.status == :completed))

        cond do
          completed_candidates == [] ->
            Result.failed!(
              "jury:result",
              RunicAI.Error.unexpected("jury did not receive any completed candidates",
                source: __MODULE__
              )
            )

          true ->
            choose_candidate(completed_candidates, evaluations, opts)
        end
    end
  end

  defp choose_candidate(completed_candidates, evaluations, opts) do
    evaluations_by_subject = Enum.group_by(evaluations, & &1.subject_id)

    required_judges =
      max(Keyword.get(opts, :required_judges, length(normalize_judge_roles(opts))), 1)

    scored_candidates =
      Enum.map(completed_candidates, fn candidate ->
        subject_evaluations = Map.get(evaluations_by_subject, candidate.task_id, [])
        score = aggregate_score(subject_evaluations)

        %{
          candidate: candidate,
          evaluations: subject_evaluations,
          score: score,
          judge_count: length(subject_evaluations)
        }
      end)

    eligible =
      Enum.filter(
        scored_candidates,
        &(&1.judge_count >= required_judges and not is_nil(&1.score))
      )

    cond do
      eligible == [] and length(completed_candidates) == 1 and evaluations == [] ->
        [winner] = completed_candidates

        Result.completed!("jury:result", winner.output,
          artifacts: winner.artifacts,
          metadata: %{winner_task_id: winner.task_id}
        )

      eligible == [] ->
        review_request =
          ReviewRequest.new!(
            :jury_review,
            checkpoint: :resolve_jury_result,
            resume_key: "review:jury:result",
            subject: %{candidates: completed_candidates, evaluations: evaluations},
            details: %{required_judges: required_judges}
          )

        Result.review!("jury:result", review_request, metadata: %{evaluations: evaluations})

      true ->
        sorted = Enum.sort_by(eligible, &{-&1.score, &1.candidate.task_id})
        [winner | rest] = sorted

        case rest do
          [%{score: tied_score} | _] when tied_score == winner.score ->
            review_request =
              ReviewRequest.new!(
                :jury_tie_break,
                checkpoint: :resolve_jury_result,
                resume_key: "review:jury:tie",
                subject: %{scores: sorted, evaluations: evaluations},
                details: %{reason: :tie}
              )

            Result.review!("jury:result", review_request, metadata: %{evaluations: evaluations})

          _ ->
            Result.completed!(
              "jury:result",
              winner.candidate.output,
              artifacts: winner.candidate.artifacts,
              metadata: %{
                winner_task_id: winner.candidate.task_id,
                winner_score: winner.score,
                evaluations: evaluations,
                scores: Enum.map(sorted, fn entry -> {entry.candidate.task_id, entry.score} end)
              }
            )
        end
    end
  end

  defp aggregate_score([]), do: nil

  defp aggregate_score(evaluations) do
    numeric_scores =
      evaluations
      |> Enum.map(fn evaluation -> evaluation.score || verdict_score(evaluation.verdict) end)
      |> Enum.reject(&is_nil/1)

    case numeric_scores do
      [] -> nil
      scores -> Enum.sum(scores) / length(scores)
    end
  end

  defp verdict_score(verdict) when verdict in [:accept, :accepted, :approve, :approved, :pass],
    do: 1.0

  defp verdict_score(verdict) when verdict in [:reject, :rejected, :fail, :failed], do: 0.0

  defp verdict_score(verdict) when is_binary(verdict),
    do: verdict |> String.downcase() |> verdict_score_from_string()

  defp verdict_score(_verdict), do: nil

  defp verdict_score_from_string(verdict)
       when verdict in ["accept", "accepted", "approve", "approved", "pass"],
       do: 1.0

  defp verdict_score_from_string(verdict)
       when verdict in ["reject", "rejected", "fail", "failed"],
       do: 0.0

  defp verdict_score_from_string(_verdict), do: nil

  defp normalize_results(results) do
    Enum.map(results, &Result.from_input!/1)
  end

  defp normalize_judge_roles(opts) do
    case Keyword.get(opts, :judge_roles) || maybe_wrap(Keyword.get(opts, :judge_role)) do
      nil -> []
      judge_roles -> judge_roles
    end
  end

  defp maybe_wrap(nil), do: nil
  defp maybe_wrap(value), do: [value]

  defp role_name(%{name: name}), do: name
  defp role_name(name) when is_binary(name), do: name

  defp role_ref(%{name: _name} = role), do: role
  defp role_ref(name) when is_binary(name), do: name

  defp latest_step_output(%Workflow{} = workflow, step_name) do
    workflow
    |> Workflow.raw_productions(step_name)
    |> List.last()
  end
end
