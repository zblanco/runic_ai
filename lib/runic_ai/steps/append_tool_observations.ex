defmodule RunicAI.Steps.AppendToolObservations do
  @moduledoc """
  Append normalized tool observations back into agent state.
  """

  require Runic

  alias RunicAI.Agent.State
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Tool.ExecutionPolicy
  alias RunicAI.Tool.Observation

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :append_tool_observations)

    Runic.step(
      fn %State{} = state, %ExecutionPlan{} = execution_plan, %BatchResult{} = batch_result ->
        append!(state, execution_plan, batch_result)
      end,
      name: name
    )
  end

  @spec append(State.t(), ExecutionPlan.t(), BatchResult.t()) ::
          {:ok, State.t()} | {:error, RunicAI.Error.t()}
  def append(%State{} = state, %ExecutionPlan{} = execution_plan, %BatchResult{} = batch_result) do
    with {:ok, state} <- State.validate(state),
         {:ok, execution_plan} <- ExecutionPlan.validate(execution_plan),
         {:ok, batch_result} <- BatchResult.validate(batch_result),
         normalized_results = batch_result.results,
         {:ok, observations} <- build_observations(normalized_results) do
      state =
        state
        |> maybe_append_observations(observations)
        |> State.clear_pending_action!()
        |> increment_tool_usage(normalized_results)
        |> maybe_apply_failure_policy(normalized_results, execution_plan.policy)

      {:ok, state}
    end
  end

  @spec append!(State.t(), ExecutionPlan.t(), BatchResult.t()) :: State.t()
  def append!(%State{} = state, %ExecutionPlan{} = execution_plan, %BatchResult{} = batch_result) do
    case append(state, execution_plan, batch_result) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp build_observations(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, acc} ->
      case Observation.from_call_result(result) do
        {:ok, observation} -> {:cont, {:ok, [observation | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, observations} -> {:ok, Enum.reverse(observations)}
      error -> error
    end
  end

  defp maybe_append_observations(state, []), do: state

  defp maybe_append_observations(state, observations) do
    State.append_messages!(state, Observation.messages(observations))
  end

  defp increment_tool_usage(%State{} = state, results) do
    metadata = state.metadata || %{}
    usage = Map.get(metadata, :usage, %{})

    usage =
      usage
      |> Map.put(:tool_calls, Map.get(usage, :tool_calls, 0) + length(results))
      |> Map.put(
        :tool_errors,
        Map.get(usage, :tool_errors, 0) + Enum.count(results, &(&1.status == :error))
      )
      |> Map.put(
        :tool_retries,
        Map.get(usage, :tool_retries, 0) + Enum.count(results, &(&1.status == :retry))
      )

    %State{state | metadata: Map.put(metadata, :usage, usage)}
  end

  defp maybe_apply_failure_policy(state, results, %ExecutionPolicy{} = policy) do
    if Enum.any?(results, &(&1.status in [:error, :retry])) do
      case ExecutionPolicy.halt_action(policy) do
        :continue -> state
        :stop -> State.with_status!(state, :completed)
        :halt -> State.with_status!(state, :halted)
      end
    else
      state
    end
  end
end
