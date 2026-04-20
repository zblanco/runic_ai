defmodule RunicAI.Tool.Executor do
  @moduledoc """
  Adapter for executing normalized tool call requests through tool definitions.
  """

  alias RunicAI.Error
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.ExecutionPolicy

  @spec execute(Definition.t(), CallRequest.t(), keyword()) :: CallResult.t()
  def execute(%Definition{} = definition, %CallRequest{} = call_request, opts \\ []) do
    execution_policy = effective_policy(definition, Keyword.get(opts, :execution_policy))
    started_at = DateTime.utc_now()

    if call_request.tool_name != definition.name do
      CallResult.error!(
        call_request,
        Error.validation("tool request does not match definition",
          source: __MODULE__,
          details: %{request_tool_name: call_request.tool_name, definition_name: definition.name}
        ),
        started_at: started_at,
        completed_at: DateTime.utc_now()
      )
    else
      execute_with_policy(definition, call_request, execution_policy, started_at)
    end
  end

  defp execute_with_policy(definition, call_request, execution_policy, started_at) do
    timeout = execution_policy.timeout

    outcome =
      case timeout do
        nil -> invoke(definition, call_request)
        :infinity -> invoke(definition, call_request)
        timeout when is_integer(timeout) -> invoke_with_timeout(definition, call_request, timeout)
      end

    completed_at = DateTime.utc_now()
    normalize_outcome(call_request, outcome, execution_policy, started_at, completed_at)
  end

  defp invoke(definition, call_request) do
    Definition.execute(definition, call_request.arguments)
  end

  defp invoke_with_timeout(definition, call_request, timeout) do
    task = Task.async(fn -> invoke(definition, call_request) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      nil ->
        {:timeout, timeout}
    end
  end

  defp normalize_outcome(call_request, {:ok, output}, _policy, started_at, completed_at) do
    CallResult.ok!(call_request, output, started_at: started_at, completed_at: completed_at)
  end

  defp normalize_outcome(
         call_request,
         {:error, %Error{retryable?: true} = error},
         _policy,
         started_at,
         completed_at
       ) do
    CallResult.retry!(call_request, error, started_at: started_at, completed_at: completed_at)
  end

  defp normalize_outcome(
         call_request,
         {:error, %Error{} = error},
         policy,
         started_at,
         completed_at
       ) do
    case retryable_policy?(policy) do
      true ->
        CallResult.retry!(call_request, error, started_at: started_at, completed_at: completed_at)

      false ->
        CallResult.error!(call_request, error, started_at: started_at, completed_at: completed_at)
    end
  end

  defp normalize_outcome(call_request, {:timeout, timeout}, policy, started_at, completed_at) do
    error =
      Error.timeout("tool execution timed out",
        source: __MODULE__,
        details: %{tool_call_id: call_request.id, timeout: timeout}
      )

    case retryable_policy?(policy) do
      true ->
        CallResult.retry!(call_request, error, started_at: started_at, completed_at: completed_at)

      false ->
        CallResult.error!(call_request, error, started_at: started_at, completed_at: completed_at)
    end
  end

  defp normalize_outcome(call_request, other, policy, started_at, completed_at) do
    error =
      Error.from_reason(other, source: __MODULE__, message: "unexpected tool executor outcome")

    case retryable_policy?(policy) do
      true ->
        CallResult.retry!(call_request, error, started_at: started_at, completed_at: completed_at)

      false ->
        CallResult.error!(call_request, error, started_at: started_at, completed_at: completed_at)
    end
  end

  defp effective_policy(definition, nil), do: definition.execution_policy
  defp effective_policy(_definition, %ExecutionPolicy{} = policy), do: policy
  defp effective_policy(_definition, policy_input), do: ExecutionPolicy.from_input!(policy_input)

  defp retryable_policy?(%ExecutionPolicy{retry: retry}), do: not is_nil(retry)
end
