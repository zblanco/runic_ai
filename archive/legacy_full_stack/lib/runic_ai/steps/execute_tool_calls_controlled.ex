defmodule RunicAI.Steps.ExecuteToolCallsControlled do
  @moduledoc """
  Execute one normalized tool batch with retry and fallback control policies.
  """

  require Runic

  alias RunicAI.Control.Recovery
  alias RunicAI.Steps.ExecuteToolCalls
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Tool.Selection

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :execute_tool_calls_controlled)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %ExecutionPlan{} = execution_plan, %Selection{} = selection ->
        execute!(execution_plan, selection, options)
      end,
      name: name
    )
  end

  @spec execute(ExecutionPlan.t(), Selection.t(), keyword()) :: term()
  def execute(%ExecutionPlan{} = execution_plan, %Selection{} = selection, opts \\ []) do
    Recovery.run(
      fn ->
        ExecuteToolCalls.execute(execution_plan, selection)
      end,
      retry_policy: Keyword.get(opts, :retry_policy),
      fallback_policy: Keyword.get(opts, :fallback_policy),
      retryable?: &retryable_batch?/1,
      fallback?: &fallback_batch?/1,
      run_fallback: fn alternate, _outcome ->
        run_alternate(execution_plan, selection, alternate)
      end
    )
  end

  @spec execute!(ExecutionPlan.t(), Selection.t(), keyword()) :: RunicAI.Tool.BatchResult.t()
  def execute!(%ExecutionPlan{} = execution_plan, %Selection{} = selection, opts \\ []) do
    case execute(execution_plan, selection, opts) do
      {:ok, batch_result} ->
        batch_result

      {:error, error} ->
        raise ArgumentError, error.message

      other ->
        raise ArgumentError, "unsupported controlled tool execution outcome: #{inspect(other)}"
    end
  end

  defp run_alternate(%ExecutionPlan{} = execution_plan, %Selection{} = selection, alternate)
       when is_function(alternate, 2) do
    alternate.(execution_plan, selection)
  end

  defp run_alternate(_execution_plan, _selection, %{
         execution_plan: %ExecutionPlan{} = replacement_plan,
         selection: %Selection{} = replacement_selection
       }) do
    ExecuteToolCalls.execute(replacement_plan, replacement_selection)
  end

  defp run_alternate(
         _execution_plan,
         %Selection{} = selection,
         %ExecutionPlan{} = replacement_plan
       ) do
    ExecuteToolCalls.execute(replacement_plan, selection)
  end

  defp run_alternate(%ExecutionPlan{} = execution_plan, %Selection{} = selection, alternate) do
    ExecuteToolCalls.execute(
      %{execution_plan | metadata: Map.put(execution_plan.metadata, :alternate, alternate)},
      selection
    )
  end

  defp retryable_batch?({:ok, %BatchResult{results: results}}) do
    Enum.any?(results, &(&1.status == :retry))
  end

  defp retryable_batch?(other) do
    match?({:retry, _}, other) or match?({:error, _}, other)
  end

  defp fallback_batch?({:ok, %BatchResult{results: results}}) do
    Enum.any?(results, &(&1.status in [:error, :retry]))
  end

  defp fallback_batch?(other) do
    match?({:retry, _}, other) or match?({:error, _}, other)
  end
end
