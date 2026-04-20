defmodule RunicAI.Steps.ReduceChildResults do
  @moduledoc """
  Deterministically reduce normalized child results with a join policy.
  """

  require Runic

  alias RunicAI.Decomposition.Callable
  alias RunicAI.Decomposition.JoinPolicy
  alias RunicAI.Decomposition.Result
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.Error
  alias RunicAI.ReviewRequest

  @type input :: %{task_plan: TaskPlan.t(), results: [Result.t()]}

  def input_step(opts \\ []) do
    name = Keyword.get(opts, :name, :reduce_child_results_input)

    Runic.step(
      fn %TaskPlan{} = task_plan, results ->
        bundle_input!(task_plan, results)
      end,
      name: name
    )
  end

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :reduce_child_results)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn %{task_plan: %TaskPlan{} = task_plan, results: results} ->
        reduce!(task_plan, results, defaults)
      end,
      name: name
    )
  end

  @spec bundle_input(TaskPlan.t(), [Result.t()]) :: {:ok, input()} | {:error, Error.t()}
  def bundle_input(%TaskPlan{} = task_plan, results) when is_list(results) do
    with {:ok, task_plan} <- TaskPlan.validate(task_plan),
         {:ok, normalized_results} <- normalize_results(results) do
      {:ok, %{task_plan: task_plan, results: normalized_results}}
    end
  end

  @spec bundle_input!(TaskPlan.t(), [Result.t()]) :: input()
  def bundle_input!(%TaskPlan{} = task_plan, results) do
    case bundle_input(task_plan, results) do
      {:ok, bundled_input} -> bundled_input
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec reduce(TaskPlan.t(), [Result.t()], keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def reduce(%TaskPlan{} = task_plan, results, opts \\ []) when is_list(results) do
    with {:ok, task_plan} <- TaskPlan.validate(task_plan),
         {:ok, results} <- normalize_results(results) do
      join_policy = Keyword.get(opts, :join_policy, task_plan.join_policy)

      aggregate_task_id =
        Keyword.get(opts, :task_id, "join:#{System.unique_integer([:positive])}")

      with {:ok, join_policy} <- JoinPolicy.from_input(join_policy) do
        {:ok, do_reduce(results, join_policy, aggregate_task_id)}
      end
    end
  end

  @spec reduce!(TaskPlan.t(), [Result.t()], keyword()) :: Result.t()
  def reduce!(%TaskPlan{} = task_plan, results, opts \\ []) do
    case reduce(task_plan, results, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp do_reduce(results, %JoinPolicy{} = join_policy, aggregate_task_id) do
    case Enum.find(results, &(&1.status in [:review, :wait, :handoff])) do
      %Result{} = control_result ->
        control_result

      nil ->
        completed = Enum.filter(results, &(&1.status == :completed))
        failed = Enum.filter(results, &(&1.status == :failed))
        cancelled = Enum.filter(results, &(&1.status == :cancelled))

        cond do
          failed != [] and completed == [] and join_policy.mode != :all_settled ->
            aggregate_failure(aggregate_task_id, failed, cancelled)

          failed != [] and completed != [] ->
            case join_policy.on_partial_failure do
              mode when mode in [:fail, :halt] ->
                aggregate_failure(aggregate_task_id, failed, cancelled)

              :review ->
                aggregate_review(aggregate_task_id, failed, completed)

              :ignore ->
                reduce_completed(completed, results, join_policy, aggregate_task_id)
            end

          true ->
            reduce_completed(completed, results, join_policy, aggregate_task_id)
        end
    end
  end

  defp reduce_completed(
         completed,
         all_results,
         %JoinPolicy{mode: :all_settled},
         aggregate_task_id
       ) do
    Result.completed!(
      aggregate_task_id,
      %{
        completed: Enum.map(completed, & &1.output),
        failed: Enum.filter(all_results, &(&1.status == :failed)),
        cancelled: Enum.filter(all_results, &(&1.status == :cancelled)),
        results: all_results
      },
      metadata: %{mode: :all_settled}
    )
  end

  defp reduce_completed(completed, _all_results, %JoinPolicy{mode: :all}, aggregate_task_id) do
    Result.completed!(
      aggregate_task_id,
      Enum.map(completed, & &1.output),
      artifacts: Enum.flat_map(completed, & &1.artifacts),
      metadata: %{mode: :all, task_ids: Enum.map(completed, & &1.task_id)}
    )
  end

  defp reduce_completed(
         completed,
         _all_results,
         %JoinPolicy{mode: :first_success},
         aggregate_task_id
       ) do
    case List.first(completed) do
      %Result{} = winner ->
        Result.completed!(
          aggregate_task_id,
          winner.output,
          artifacts: winner.artifacts,
          metadata: %{mode: :first_success, winner_task_id: winner.task_id}
        )

      nil ->
        aggregate_failure(aggregate_task_id, [], [])
    end
  end

  defp reduce_completed(
         completed,
         _all_results,
         %JoinPolicy{mode: :quorum, quorum: quorum},
         aggregate_task_id
       ) do
    case length(completed) >= quorum do
      true ->
        selected = Enum.take(completed, quorum)

        Result.completed!(
          aggregate_task_id,
          Enum.map(selected, & &1.output),
          artifacts: Enum.flat_map(selected, & &1.artifacts),
          metadata: %{mode: :quorum, quorum: quorum, task_ids: Enum.map(selected, & &1.task_id)}
        )

      false ->
        Result.failed!(
          aggregate_task_id,
          Error.unexpected("decomposition quorum not reached",
            source: __MODULE__,
            details: %{quorum: quorum, completed_task_ids: Enum.map(completed, & &1.task_id)}
          )
        )
    end
  end

  defp reduce_completed(
         completed,
         _all_results,
         %JoinPolicy{mode: :score} = join_policy,
         aggregate_task_id
       ) do
    case pick_highest_score(completed, join_policy) do
      nil ->
        aggregate_failure(aggregate_task_id, [], [])

      {winner, score} ->
        Result.completed!(
          aggregate_task_id,
          winner.output,
          artifacts: winner.artifacts,
          metadata: %{mode: :score, winner_task_id: winner.task_id, score: score}
        )
    end
  end

  defp reduce_completed(
         completed,
         _all_results,
         %JoinPolicy{mode: :merge} = join_policy,
         aggregate_task_id
       ) do
    case merge_outputs(completed, join_policy) do
      {:ok, merged_output} ->
        Result.completed!(
          aggregate_task_id,
          merged_output,
          artifacts: Enum.flat_map(completed, & &1.artifacts),
          metadata: %{
            mode: :merge,
            task_ids: Enum.map(completed, & &1.task_id),
            merge_conflicts: join_policy.merge_conflicts
          }
        )

      {:error, error} ->
        Result.failed!(
          aggregate_task_id,
          error,
          metadata: %{mode: :merge, merge_conflicts: join_policy.merge_conflicts}
        )
    end
  end

  defp reduce_completed(
         completed,
         _all_results,
         %JoinPolicy{mode: :custom} = join_policy,
         aggregate_task_id
       ) do
    synthesized =
      Callable.invoke(join_policy.synthesizer, %{
        completed: completed,
        outputs: Enum.map(completed, & &1.output),
        task_ids: Enum.map(completed, & &1.task_id)
      })

    normalize_join_output(synthesized, aggregate_task_id, completed)
  end

  defp normalize_join_output(%Result{} = result, _aggregate_task_id, _completed), do: result

  defp normalize_join_output({:ok, value}, aggregate_task_id, completed) do
    normalize_join_output(value, aggregate_task_id, completed)
  end

  defp normalize_join_output({:error, reason}, aggregate_task_id, _completed) do
    Result.failed!(aggregate_task_id, reason)
  end

  defp normalize_join_output(%ReviewRequest{} = review_request, aggregate_task_id, _completed) do
    Result.review!(aggregate_task_id, review_request)
  end

  defp normalize_join_output(value, aggregate_task_id, completed) when is_map(value) do
    cond do
      Map.has_key?(value, :status) or Map.has_key?(value, "status") ->
        value
        |> Map.new()
        |> Map.put_new(:task_id, aggregate_task_id)
        |> Result.from_input!()

      true ->
        Result.completed!(
          aggregate_task_id,
          value,
          artifacts: Enum.flat_map(completed, & &1.artifacts),
          metadata: %{mode: :custom}
        )
    end
  end

  defp normalize_join_output(value, aggregate_task_id, completed) do
    Result.completed!(
      aggregate_task_id,
      value,
      artifacts: Enum.flat_map(completed, & &1.artifacts),
      metadata: %{mode: :custom}
    )
  end

  defp pick_highest_score([], _join_policy), do: nil

  defp pick_highest_score(results, %JoinPolicy{} = join_policy) do
    Enum.max_by(results, &score_result(&1, join_policy), fn -> nil end)
    |> case do
      nil -> nil
      %Result{} = winner -> {winner, score_result(winner, join_policy)}
    end
  end

  defp score_result(%Result{} = result, %JoinPolicy{score_by: nil}) do
    metadata_score(result) || output_score(result) || 0
  end

  defp score_result(%Result{} = result, %JoinPolicy{score_by: key})
       when is_atom(key) or is_binary(key) do
    output = result.output
    get_value(output, key) || get_value(result.metadata, key) || 0
  end

  defp score_result(%Result{} = result, %JoinPolicy{score_by: callable}) do
    Callable.invoke(callable, result)
  end

  defp metadata_score(%Result{} = result) do
    get_value(result.metadata, :score)
  end

  defp output_score(%Result{output: output}) when is_number(output), do: output

  defp output_score(%Result{output: output}) when is_map(output) do
    get_value(output, :score)
  end

  defp output_score(_result), do: nil

  defp merge_outputs(completed, %JoinPolicy{merge_conflicts: :nest_by_task}) do
    {:ok,
     Map.new(completed, fn %Result{} = result ->
       {result.task_id, result.output}
     end)}
  end

  defp merge_outputs(completed, %JoinPolicy{} = join_policy) do
    outputs = Enum.map(completed, & &1.output)

    cond do
      outputs == [] ->
        {:ok, []}

      Enum.all?(outputs, &is_map/1) ->
        merge_map_outputs(completed, join_policy.merge_conflicts)

      Enum.all?(outputs, &is_list/1) ->
        {:ok, Enum.flat_map(outputs, & &1)}

      true ->
        {:ok, outputs}
    end
  end

  defp merge_map_outputs(completed, :last_wins) do
    {:ok,
     Enum.reduce(completed, %{}, fn %Result{output: output}, acc ->
       Map.merge(acc, output)
     end)}
  end

  defp merge_map_outputs(completed, :first_wins) do
    {:ok,
     Enum.reduce(completed, %{}, fn %Result{output: output}, acc ->
       Map.merge(acc, output, fn _key, existing, _incoming -> existing end)
     end)}
  end

  defp merge_map_outputs(completed, :error) do
    case conflicting_map_keys(completed) do
      [] ->
        merge_map_outputs(completed, :last_wins)

      conflicts ->
        {:error,
         Error.validation("merge join encountered conflicting keys across child outputs",
           source: __MODULE__,
           details: %{conflicts: conflicts, task_ids: Enum.map(completed, & &1.task_id)}
         )}
    end
  end

  defp conflicting_map_keys(completed) do
    completed
    |> Enum.reduce(%{}, fn %Result{} = result, acc ->
      Enum.reduce(result.output, acc, fn {key, value}, key_acc ->
        Map.update(key_acc, key, [{result.task_id, value}], &[{result.task_id, value} | &1])
      end)
    end)
    |> Enum.reduce([], fn {key, entries}, acc ->
      distinct_values =
        entries
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()

      if length(distinct_values) > 1 do
        [
          %{
            key: key,
            entries: Enum.reverse(entries)
          }
          | acc
        ]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp aggregate_failure(aggregate_task_id, failed, cancelled) do
    Result.failed!(
      aggregate_task_id,
      Error.unexpected("child execution did not produce a reducible successful result",
        source: __MODULE__,
        details: %{
          failed_task_ids: Enum.map(failed, & &1.task_id),
          cancelled_task_ids: Enum.map(cancelled, & &1.task_id)
        }
      ),
      metadata: %{failed_count: length(failed), cancelled_count: length(cancelled)}
    )
  end

  defp aggregate_review(aggregate_task_id, failed, completed) do
    review_request =
      ReviewRequest.new!(
        :child_join_review,
        checkpoint: :reduce_child_results,
        resume_key: "review:join:#{aggregate_task_id}",
        subject: %{completed: completed, failed: failed},
        details: %{
          failed_task_ids: Enum.map(failed, & &1.task_id),
          completed_task_ids: Enum.map(completed, & &1.task_id)
        }
      )

    Result.review!(aggregate_task_id, review_request, metadata: %{mode: :review})
  end

  defp normalize_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, acc} ->
      case Result.from_input(result) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp get_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_value(_map, _key), do: nil
end
