defmodule RunicAI.Steps.PlanToolExecution do
  @moduledoc """
  Build an explicit execution plan for one batch of tool calls.
  """

  require Runic

  alias RunicAI.Agent.TurnResult
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Tool.ExecutionPolicy
  alias RunicAI.Tool.Selection

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :plan_tool_execution)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnResult{} = turn_result, %Selection{} = selection ->
        plan!(turn_result, selection, options)
      end,
      name: name
    )
  end

  @spec plan(TurnResult.t(), Selection.t(), keyword()) ::
          {:ok, ExecutionPlan.t()} | {:error, RunicAI.Error.t()}
  def plan(%TurnResult{} = turn_result, %Selection{} = selection, opts \\ []) do
    with {:ok, turn_result} <- TurnResult.validate(turn_result),
         {:ok, selection} <- Selection.validate(selection) do
      case turn_result do
        %TurnResult{kind: :tool_requests} ->
          build_tool_plan(turn_result, selection, opts)

        _ ->
          ExecutionPlan.new([],
            policy: Keyword.get(opts, :execution_policy),
            metadata: %{reason: :no_tool_requests}
          )
      end
    end
  end

  @spec plan!(TurnResult.t(), Selection.t(), keyword()) :: ExecutionPlan.t()
  def plan!(%TurnResult{} = turn_result, %Selection{} = selection, opts \\ []) do
    case plan(turn_result, selection, opts) do
      {:ok, execution_plan} -> execution_plan
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp build_tool_plan(%TurnResult{details: details}, selection, opts) do
    with {:ok, calls} <- normalize_calls(Map.get(details, :tool_calls, [])),
         {:ok, effective_policy} <- effective_policy(calls, selection, opts),
         {:ok, execution_plan} <- plan_from_selector(calls, selection, effective_policy, opts) do
      {:ok, execution_plan}
    end
  end

  defp normalize_calls(tool_calls) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn tool_call, {:ok, acc} ->
      case normalize_call(tool_call) do
        {:ok, normalized_call} -> {:cont, {:ok, [normalized_call | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp normalize_call(%CallRequest{} = call_request), do: CallRequest.validate(call_request)

  defp normalize_call(other) do
    {:error,
     RunicAI.Error.validation("tool execution plans require Tool.CallRequest values",
       source: __MODULE__,
       details: %{tool_call: other}
     )}
  end

  defp effective_policy(calls, selection, opts) do
    case Keyword.get(opts, :execution_policy) do
      nil ->
        derive_policy_from_tools(calls, selection)

      policy ->
        ExecutionPolicy.from_input(policy)
    end
  end

  defp derive_policy_from_tools(calls, selection) do
    definitions =
      Enum.map(calls, fn call ->
        Selection.fetch_visible!(selection, call.tool_name)
      end)

    mode =
      cond do
        staged_mode = Enum.find_value(definitions, &staged_mode/1) -> staged_mode
        Enum.any?(definitions, &(&1.execution_policy.mode == :serial)) -> :serial
        true -> :parallel
      end

    timeout = merged_timeout(definitions)
    max_concurrency = merged_max_concurrency(definitions)
    retry = Enum.find_value(definitions, & &1.execution_policy.retry)
    dispatch = Enum.find_value(definitions, &dispatch_hint/1) || :immediate
    stop_on_error = merged_stop_on_error(definitions)

    ExecutionPolicy.new(
      mode: mode,
      timeout: timeout,
      max_concurrency: max_concurrency,
      retry: retry,
      dispatch: dispatch,
      stop_on_error: stop_on_error
    )
  end

  defp plan_from_selector(calls, selection, effective_policy, opts) do
    case Keyword.get(opts, :planner) do
      nil ->
        ExecutionPlan.new(calls,
          policy: effective_policy,
          groups: groups_for_policy(effective_policy),
          metadata: %{reason: :default}
        )

      planner when is_function(planner, 3) ->
        planner.(calls, selection, effective_policy)
        |> normalize_planner_result(calls, effective_policy)
    end
  end

  defp normalize_planner_result({:ok, %ExecutionPlan{} = execution_plan}, _calls, _policy),
    do: ExecutionPlan.validate(execution_plan)

  defp normalize_planner_result(%ExecutionPlan{} = execution_plan, _calls, _policy),
    do: ExecutionPlan.validate(execution_plan)

  defp normalize_planner_result(groups, calls, effective_policy) when is_list(groups) do
    ExecutionPlan.new(calls,
      policy: %{effective_policy | mode: {:staged, groups}},
      groups: groups,
      metadata: %{reason: :custom}
    )
  end

  defp normalize_planner_result(other, _calls, _policy) do
    {:error,
     RunicAI.Error.validation("unsupported tool planner result: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp groups_for_policy(%ExecutionPolicy{mode: {:staged, groups}}), do: groups
  defp groups_for_policy(_policy), do: nil

  defp staged_mode(%{execution_policy: %ExecutionPolicy{mode: {:staged, groups}}}),
    do: {:staged, groups}

  defp staged_mode(_definition), do: nil

  defp merged_timeout(definitions) do
    timeouts =
      definitions
      |> Enum.map(& &1.execution_policy.timeout)
      |> Enum.reject(&is_nil/1)

    cond do
      timeouts == [] ->
        30_000

      Enum.all?(timeouts, &(&1 == :infinity)) ->
        :infinity

      true ->
        timeouts
        |> Enum.reject(&(&1 == :infinity))
        |> Enum.min()
    end
  end

  defp merged_max_concurrency(definitions) do
    definitions
    |> Enum.map(& &1.execution_policy.max_concurrency)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> Enum.min(values)
    end
  end

  defp dispatch_hint(%{execution_policy: %ExecutionPolicy{dispatch: :immediate}}), do: nil
  defp dispatch_hint(%{execution_policy: %ExecutionPolicy{dispatch: dispatch}}), do: dispatch

  defp merged_stop_on_error(definitions) do
    definitions
    |> Enum.map(& &1.execution_policy.stop_on_error)
    |> Enum.find(false, fn stop_on_error -> stop_on_error in [:halt, true, :stop] end)
  end
end
