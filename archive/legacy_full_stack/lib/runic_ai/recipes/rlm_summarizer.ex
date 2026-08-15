defmodule RunicAI.Recipes.RLMSummarizer do
  @moduledoc """
  Minimal RLM-style summarizer workflow.

  The recipe proves the first useful vertical slice:

  source ref -> split -> late materialization -> bounded leaf mapping -> reduce
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.RLM.ReductionResult
  alias RunicAI.Steps.RLMMaterialize
  alias RunicAI.Steps.RLMMapLeaves
  alias RunicAI.Steps.RLMReduce
  alias RunicAI.Steps.RLMSplit

  @spec new(keyword()) :: Workflow.t()
  def new(opts \\ []) do
    input_step =
      Runic.step(
        fn input -> input end,
        name: :rlm_summarizer_input
      )

    split_step =
      RLMSplit.new(
        name: :rlm_split,
        chunk_size: Keyword.get(opts, :chunk_size, 4_000),
        overlap: Keyword.get(opts, :overlap, 0)
      )

    materialize_input_step =
      Runic.step(
        fn slice_set, input ->
          %{slice_set: slice_set, environment: Map.get(input, :environment)}
        end,
        name: :rlm_materialize_input
      )

    materialize_step = RLMMaterialize.new(name: :rlm_materialize)

    map_step =
      RLMMapLeaves.new(
        name: :rlm_map_leaves,
        mapper: Keyword.get(opts, :mapper, &default_leaf_summary/1)
      )

    reduce_step =
      RLMReduce.new(
        name: :rlm_reduce,
        reducer: Keyword.get(opts, :reducer, &default_reduce/1)
      )

    Workflow.new(name: Keyword.get(opts, :name, :rlm_summarizer))
    |> Workflow.add(input_step)
    |> Workflow.add(split_step, to: :rlm_summarizer_input)
    |> Workflow.add(materialize_input_step, to: [:rlm_split, :rlm_summarizer_input])
    |> Workflow.add(materialize_step, to: :rlm_materialize_input)
    |> Workflow.add(map_step, to: :rlm_materialize)
    |> Workflow.add(reduce_step, to: :rlm_map_leaves)
  end

  @spec react_until_resolution(keyword(), map(), keyword()) :: Workflow.t()
  def react_until_resolution(opts, input, react_opts \\ [])
      when is_list(opts) and is_map(input) do
    opts
    |> new()
    |> Workflow.react_until_satisfied(input, react_opts)
  end

  @spec latest_result(Workflow.t()) :: ReductionResult.t() | nil
  def latest_result(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions(:rlm_reduce)
    |> List.last()
  end

  @spec latest_output(Workflow.t()) :: term()
  def latest_output(%Workflow{} = workflow) do
    case latest_result(workflow) do
      %ReductionResult{} = result -> result.output
      _ -> nil
    end
  end

  defp default_leaf_summary(artifact), do: artifact.content

  defp default_reduce(results) do
    results
    |> Enum.map(&to_string(&1.output))
    |> Enum.join("\n\n")
  end
end
