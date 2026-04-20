defmodule RunicAI.Steps.ExecuteToolCalls do
  @moduledoc """
  Execute one normalized tool batch according to its execution plan.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Error
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Tool.ExecutionPolicy
  alias RunicAI.Tool.Executor
  alias RunicAI.Tool.Selection

  @type input :: %{execution_plan: ExecutionPlan.t(), selection: Selection.t()}

  def input_step(opts \\ []) do
    name = Keyword.get(opts, :name, :execute_tool_calls_input)

    Runic.step(
      fn %ExecutionPlan{} = execution_plan, %Selection{} = selection ->
        bundle_input!(execution_plan, selection)
      end,
      name: name
    )
  end

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :execute_tool_calls)

    Runic.step(
      fn %{execution_plan: %ExecutionPlan{} = execution_plan, selection: %Selection{} = selection} ->
        execute!(execution_plan, selection)
      end,
      name: name
    )
  end

  @spec bundle_input(ExecutionPlan.t(), Selection.t()) :: {:ok, input()} | {:error, Error.t()}
  def bundle_input(%ExecutionPlan{} = execution_plan, %Selection{} = selection) do
    with {:ok, execution_plan} <- ExecutionPlan.validate(execution_plan),
         {:ok, selection} <- Selection.validate(selection) do
      {:ok, %{execution_plan: execution_plan, selection: selection}}
    end
  end

  @spec bundle_input!(ExecutionPlan.t(), Selection.t()) :: input()
  def bundle_input!(%ExecutionPlan{} = execution_plan, %Selection{} = selection) do
    case bundle_input(execution_plan, selection) do
      {:ok, bundled_input} -> bundled_input
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec execute(ExecutionPlan.t(), Selection.t()) ::
          {:ok, BatchResult.t()} | {:error, Error.t()}
  def execute(%ExecutionPlan{} = execution_plan, %Selection{} = selection) do
    with {:ok, execution_plan} <- ExecutionPlan.validate(execution_plan),
         {:ok, selection} <- Selection.validate(selection) do
      results =
        case execution_plan.policy.mode do
          :parallel ->
            execute_parallel(execution_plan.calls, selection, execution_plan.policy)

          :serial ->
            execute_serial(execution_plan.calls, selection, execution_plan.policy)

          {:staged, groups} ->
            execute_staged(execution_plan.calls, groups, selection, execution_plan.policy)
        end

      BatchResult.new(results, metadata: %{mode: execution_plan.policy.mode})
    end
  end

  @spec execute!(ExecutionPlan.t(), Selection.t()) :: BatchResult.t()
  def execute!(%ExecutionPlan{} = execution_plan, %Selection{} = selection) do
    case execute(execution_plan, selection) do
      {:ok, batch_result} -> batch_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp execute_parallel([], _selection, _policy), do: []

  defp execute_parallel(calls, selection, %ExecutionPolicy{} = policy) do
    map_name = :execute_tool_call_parallel_map
    reduce_name = :execute_tool_call_parallel_reduce

    workflow =
      Workflow.new(name: :execute_tool_calls_parallel_workflow)
      |> Workflow.add(
        Runic.map(
          fn %CallRequest{} = call_request ->
            safe_execute_one(call_request, selection, policy)
          end,
          name: map_name
        )
      )
      |> Workflow.add(
        Runic.reduce(
          [],
          fn %CallResult{} = result, acc -> [result | acc] end,
          name: reduce_name,
          map: map_name
        ),
        to: map_name
      )
      |> Workflow.plan_eagerly(calls)
      |> Workflow.react_until_satisfied()

    case Workflow.raw_productions(workflow, reduce_name) |> List.last() do
      results when is_list(results) -> Enum.sort_by(results, & &1.request.request_index)
      _ -> []
    end
  end

  defp execute_serial(calls, selection, policy) do
    Enum.map(calls, &safe_execute_one(&1, selection, policy))
  end

  defp execute_staged(calls, groups, selection, policy) do
    groups
    |> resolve_groups(calls)
    |> Enum.flat_map(fn group_calls ->
      if length(group_calls) <= 1 do
        execute_serial(group_calls, selection, policy)
      else
        execute_parallel(group_calls, selection, policy)
      end
    end)
  end

  defp resolve_groups(groups, calls) do
    resolved_groups =
      Enum.map(groups, fn group ->
        Enum.map(group, fn
          %CallRequest{} = call_request ->
            call_request

          call_id when is_binary(call_id) ->
            Enum.find(calls, &(&1.id == call_id)) ||
              raise ArgumentError, "unknown tool call id in staged plan: #{inspect(call_id)}"

          other ->
            raise ArgumentError, "unsupported staged tool call reference: #{inspect(other)}"
        end)
      end)

    already_grouped = resolved_groups |> List.flatten()
    remaining_calls = Enum.reject(calls, &(&1 in already_grouped))

    case remaining_calls do
      [] -> resolved_groups
      _ -> resolved_groups ++ [remaining_calls]
    end
  end

  defp execute_one(
         %CallRequest{} = call_request,
         %Selection{} = selection,
         %ExecutionPolicy{} = policy
       ) do
    definition = Selection.fetch_visible!(selection, call_request.tool_name)
    Executor.execute(definition, call_request, execution_policy: policy)
  end

  defp safe_execute_one(
         %CallRequest{} = call_request,
         %Selection{} = selection,
         %ExecutionPolicy{} = policy
       ) do
    execute_one(call_request, selection, policy)
  rescue
    exception ->
      CallResult.error!(call_request, Error.from_exception(exception, source: __MODULE__))
  catch
    kind, reason ->
      CallResult.error!(call_request, Error.from_reason({kind, reason}, source: __MODULE__))
  end
end
