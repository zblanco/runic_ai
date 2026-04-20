defmodule RunicAI.Steps.EvaluateBudget do
  @moduledoc """
  Evaluate resource usage against a declarative budget policy.
  """

  require Runic

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Control.BudgetDecision
  alias RunicAI.Control.BudgetPolicy
  alias RunicAI.Control.BudgetSnapshot
  alias RunicAI.Error
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.ExecutionPlan

  @type input :: %{
          required(:state) => State.t(),
          optional(:turn_result) => TurnResult.t() | nil,
          optional(:execution_plan) => ExecutionPlan.t() | nil,
          optional(:batch_result) => BatchResult.t() | nil,
          optional(:runtime) => map()
        }

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :evaluate_budget)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        evaluate!(input, options)
      end,
      name: name
    )
  end

  @spec evaluate(input(), keyword()) :: {:ok, BudgetDecision.t()} | {:error, Error.t()}
  def evaluate(input, opts \\ []) when is_map(input) and is_list(opts) do
    with {:ok, normalized_input} <- validate_input(input),
         {:ok, snapshot} <- build_snapshot(normalized_input),
         {:ok, budget_policy} <- normalize_budget_policy(Keyword.get(opts, :budget_policy)) do
      {:ok, evaluate_policy(snapshot, budget_policy)}
    end
  end

  @spec evaluate!(input(), keyword()) :: BudgetDecision.t()
  def evaluate!(input, opts \\ []) do
    case evaluate(input, opts) do
      {:ok, budget_decision} -> budget_decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec build_snapshot(input()) :: {:ok, BudgetSnapshot.t()} | {:error, Error.t()}
  def build_snapshot(input) when is_map(input) do
    with {:ok, %{state: %State{} = state} = normalized_input} <- validate_input(input) do
      usage = normalize_map(get_in(state.metadata, [:usage]))
      timing = normalize_map(get_in(state.metadata, [:timing]))
      runtime = Map.get(normalized_input, :runtime, %{})
      projected_tool_calls = projected_tool_calls(normalized_input)

      BudgetSnapshot.new(
        turns: state.conversation.turns,
        model_calls: Map.get(usage, :model_calls, state.conversation.turns),
        tool_calls: Map.get(usage, :tool_calls, 0) + projected_tool_calls,
        elapsed_ms: elapsed_ms(runtime, timing),
        estimated_cost: estimated_cost(runtime, usage),
        recursion_depth: Map.get(runtime, :recursion_depth, 0),
        metadata: %{
          projected_tool_calls: projected_tool_calls,
          runtime: runtime
        }
      )
    end
  end

  @spec validate_input(map()) :: {:ok, input()} | {:error, Error.t()}
  def validate_input(%{state: %State{} = state} = input) do
    with {:ok, state} <- State.validate(state),
         {:ok, turn_result} <- normalize_turn_result(Map.get(input, :turn_result)),
         {:ok, execution_plan} <- normalize_execution_plan(Map.get(input, :execution_plan)),
         {:ok, batch_result} <- normalize_batch_result(Map.get(input, :batch_result)),
         :ok <- validate_runtime(Map.get(input, :runtime, %{})) do
      {:ok,
       %{
         state: state,
         turn_result: turn_result,
         execution_plan: execution_plan,
         batch_result: batch_result,
         runtime: Map.get(input, :runtime, %{})
       }}
    end
  end

  def validate_input(other) do
    {:error,
     Error.validation("budget input must include an Agent.State",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  defp normalize_budget_policy(nil), do: {:ok, nil}
  defp normalize_budget_policy(policy), do: BudgetPolicy.from_input(policy)

  defp evaluate_policy(%BudgetSnapshot{} = snapshot, nil) do
    BudgetDecision.new!(:within_limits, :continue, snapshot)
  end

  defp evaluate_policy(%BudgetSnapshot{} = snapshot, %BudgetPolicy{} = budget_policy) do
    limits = [
      {:turns, snapshot.turns, budget_policy.max_turns},
      {:model_calls, snapshot.model_calls, budget_policy.max_model_calls},
      {:tool_calls, snapshot.tool_calls, budget_policy.max_tool_calls},
      {:elapsed_ms, snapshot.elapsed_ms, budget_policy.max_elapsed_ms},
      {:estimated_cost, snapshot.estimated_cost, budget_policy.max_estimated_cost},
      {:recursion_depth, snapshot.recursion_depth, budget_policy.max_recursion_depth}
    ]

    exhausted_reasons =
      Enum.flat_map(limits, fn
        {_metric, _actual, nil} ->
          []

        {metric, actual, limit} when actual > limit ->
          [%{metric: metric, actual: actual, limit: limit, status: :exhausted}]

        _ ->
          []
      end)

    soft_limit_reasons =
      Enum.flat_map(limits, fn
        {_metric, _actual, nil} ->
          []

        {metric, actual, limit} when actual == limit ->
          [%{metric: metric, actual: actual, limit: limit, status: :soft_limit}]

        _ ->
          []
      end)

    cond do
      exhausted_reasons != [] ->
        BudgetDecision.new!(
          :exhausted,
          budget_policy.on_exhaustion,
          snapshot,
          reasons: exhausted_reasons,
          metadata: budget_policy.metadata
        )

      soft_limit_reasons != [] ->
        BudgetDecision.new!(
          :soft_limit,
          :continue,
          snapshot,
          reasons: soft_limit_reasons,
          metadata: budget_policy.metadata
        )

      true ->
        BudgetDecision.new!(:within_limits, :continue, snapshot, metadata: budget_policy.metadata)
    end
  end

  defp normalize_turn_result(nil), do: {:ok, nil}
  defp normalize_turn_result(%TurnResult{} = turn_result), do: TurnResult.validate(turn_result)

  defp normalize_turn_result(other) do
    {:error,
     Error.validation("budget turn_result must be a TurnResult or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp normalize_execution_plan(nil), do: {:ok, nil}

  defp normalize_execution_plan(%ExecutionPlan{} = execution_plan),
    do: ExecutionPlan.validate(execution_plan)

  defp normalize_execution_plan(other) do
    {:error,
     Error.validation("budget execution_plan must be an ExecutionPlan or nil",
       source: __MODULE__,
       details: %{execution_plan: other}
     )}
  end

  defp normalize_batch_result(nil), do: {:ok, nil}

  defp normalize_batch_result(%BatchResult{} = batch_result),
    do: BatchResult.validate(batch_result)

  defp normalize_batch_result(other) do
    {:error,
     Error.validation("budget batch_result must be a BatchResult or nil",
       source: __MODULE__,
       details: %{batch_result: other}
     )}
  end

  defp validate_runtime(runtime) when is_map(runtime), do: :ok

  defp validate_runtime(runtime) do
    {:error,
     Error.validation("budget runtime must be a map, got: #{inspect(runtime)}",
       source: __MODULE__
     )}
  end

  defp projected_tool_calls(%{execution_plan: %ExecutionPlan{calls: calls}, batch_result: nil}),
    do: length(calls)

  defp projected_tool_calls(%{batch_result: %BatchResult{results: results}}), do: length(results)
  defp projected_tool_calls(_input), do: 0

  defp elapsed_ms(runtime, timing) do
    cond do
      is_integer(Map.get(runtime, :elapsed_ms)) ->
        Map.get(runtime, :elapsed_ms)

      is_integer(Map.get(timing, :elapsed_ms)) ->
        Map.get(timing, :elapsed_ms)

      true ->
        case Map.get(timing, :started_at) do
          %DateTime{} = started_at -> DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
          _ -> 0
        end
    end
  end

  defp estimated_cost(runtime, usage) do
    cond do
      is_number(Map.get(runtime, :estimated_cost)) -> Map.get(runtime, :estimated_cost)
      is_number(Map.get(usage, :estimated_cost)) -> Map.get(usage, :estimated_cost)
      true -> 0.0
    end
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}
end
