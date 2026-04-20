defmodule RunicAI.Steps.JudgeCandidates do
  @moduledoc """
  Normalize completed judge outputs into `RunicAI.Decomposition.Evaluation`
  values.
  """

  require Runic

  alias RunicAI.Decomposition.Callable
  alias RunicAI.Decomposition.Evaluation
  alias RunicAI.Decomposition.Result

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :judge_candidates)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        judge!(input, defaults)
      end,
      name: name
    )
  end

  @spec judge([Result.t()] | map(), keyword()) ::
          {:ok, [Evaluation.t()]} | {:error, RunicAI.Error.t()}
  def judge(input, opts \\ []) when is_list(opts) do
    results = extract_results(input)

    with {:ok, normalized_results} <- normalize_results(results) do
      normalized_results
      |> Enum.filter(&(&1.status == :completed))
      |> Enum.reduce_while({:ok, []}, fn result, {:ok, acc} ->
        case normalize_evaluation(result, opts) do
          {:ok, evaluation} -> {:cont, {:ok, [evaluation | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, evaluations} -> {:ok, Enum.reverse(evaluations)}
        error -> error
      end
    end
  end

  @spec judge!([Result.t()] | map(), keyword()) :: [Evaluation.t()]
  def judge!(input, opts \\ []) do
    case judge(input, opts) do
      {:ok, evaluations} -> evaluations
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp extract_results(input) when is_list(input), do: input

  defp extract_results(input) when is_map(input) do
    Map.get(input, :judge_results) ||
      Map.get(input, "judge_results") ||
      Map.get(input, :results) ||
      Map.get(input, "results") ||
      []
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

  defp normalize_evaluation(%Result{} = result, opts) do
    extractor = Keyword.get(opts, :extractor) || Keyword.get(opts, :evaluator)

    value =
      case extractor do
        nil -> result.output
        callable -> Callable.invoke(callable, result)
      end

    subject_id =
      get_value(result.metadata, :subject_id) ||
        get_value(value, :subject_id) ||
        result.task_id

    judge =
      get_value(result.metadata, :judge) ||
        get_value(value, :judge) ||
        get_value(result.metadata, :role)

    case value do
      %Evaluation{} = evaluation ->
        Evaluation.validate(evaluation)

      score when is_number(score) ->
        Evaluation.new(
          subject_id: subject_id,
          judge: judge,
          score: score,
          metadata: result.metadata
        )

      verdict when is_atom(verdict) or is_binary(verdict) ->
        Evaluation.new(
          subject_id: subject_id,
          judge: judge,
          verdict: verdict,
          metadata: result.metadata
        )

      evaluation_map when is_map(evaluation_map) ->
        evaluation_map
        |> Map.new()
        |> Map.put_new(:subject_id, subject_id)
        |> Map.put_new(:judge, judge)
        |> Map.put_new(:metadata, result.metadata)
        |> Evaluation.from_input()

      other ->
        {:error,
         RunicAI.Error.validation("judge output is not Evaluation-compatible",
           source: __MODULE__,
           details: %{output: other, task_id: result.task_id}
         )}
    end
  end

  defp get_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_value(_map, _key), do: nil
end
