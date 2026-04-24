defmodule RunicAI.Steps.RLMReduce do
  @moduledoc """
  Runic step that reduces RLM leaf results.
  """

  require Runic

  alias RunicAI.RLM.LeafResult
  alias RunicAI.RLM.ReductionResult

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :rlm_reduce)
    reducer = Keyword.get(opts, :reducer, &concat_outputs/1)

    Runic.step(
      fn leaf_results ->
        reduce!(List.wrap(leaf_results), reducer)
      end,
      name: name
    )
  end

  @spec reduce([LeafResult.t()], ([LeafResult.t()] -> term())) ::
          {:ok, ReductionResult.t()} | {:error, RunicAI.Error.t()}
  def reduce(leaf_results, reducer) when is_list(leaf_results) and is_function(reducer, 1) do
    with {:ok, normalized} <- normalize_results(leaf_results),
         {:ok, output} <- call_reducer(reducer, normalized) do
      ReductionResult.new(output,
        id: "reduction:rlm",
        children: normalized,
        metadata: %{leaf_result_ids: Enum.map(normalized, & &1.id)}
      )
    end
  end

  @spec reduce!([LeafResult.t()], ([LeafResult.t()] -> term())) :: ReductionResult.t()
  def reduce!(leaf_results, reducer) do
    case reduce(leaf_results, reducer) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      %LeafResult{} = result, {:ok, acc} ->
        case LeafResult.validate(result) do
          {:ok, result} -> {:cont, {:ok, [result | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      other, _acc ->
        {:halt,
         {:error,
          RunicAI.Error.validation("RLM reducer expects LeafResult values",
            source: __MODULE__,
            details: %{value: other}
          )}}
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp call_reducer(reducer, results) do
    case reducer.(results) do
      {:ok, output} -> {:ok, output}
      {:error, %RunicAI.Error{} = error} -> {:error, error}
      output -> {:ok, output}
    end
  end

  defp concat_outputs(results) do
    results
    |> Enum.map(&to_string(&1.output))
    |> Enum.join("\n\n")
  end
end
