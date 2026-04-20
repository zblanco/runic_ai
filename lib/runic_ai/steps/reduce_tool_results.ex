defmodule RunicAI.Steps.ReduceToolResults do
  @moduledoc """
  Deterministically reduce a batch of tool call results.
  """

  require Runic

  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.ExecutionPlan

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :reduce_tool_results)

    Runic.step(
      fn %ExecutionPlan{} = execution_plan, %BatchResult{} = batch_result ->
        reduce!(execution_plan, batch_result)
      end,
      name: name
    )
  end

  @spec reduce(ExecutionPlan.t(), BatchResult.t()) ::
          {:ok, BatchResult.t()} | {:error, RunicAI.Error.t()}
  def reduce(%ExecutionPlan{} = execution_plan, %BatchResult{} = batch_result) do
    with {:ok, _execution_plan} <- ExecutionPlan.validate(execution_plan),
         {:ok, batch_result} <- BatchResult.validate(batch_result) do
      BatchResult.new(
        Enum.sort_by(batch_result.results, & &1.request.request_index),
        metadata: batch_result.metadata
      )
    end
  end

  @spec reduce!(ExecutionPlan.t(), BatchResult.t()) :: BatchResult.t()
  def reduce!(%ExecutionPlan{} = execution_plan, %BatchResult{} = batch_result) do
    case reduce(execution_plan, batch_result) do
      {:ok, reduced_results} -> reduced_results
      {:error, error} -> raise ArgumentError, error.message
    end
  end
end
