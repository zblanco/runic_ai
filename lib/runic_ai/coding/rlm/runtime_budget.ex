defmodule RunicAI.Coding.RLM.RuntimeBudget do
  @moduledoc """
  Wall-clock budget helper for RLM coding orchestration.

  Turn, tool, and command limits are necessary but not sufficient: an agent can
  still spend too long across model calls, tool loops, or generated project
  verification. This helper wraps a bounded unit of orchestration and returns a
  structured error on timeout instead of leaving the caller blocked.
  """

  alias RunicAI.Error

  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec run((-> result(term())), keyword()) :: result(term())
  def run(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    case Keyword.get(opts, :timeout_ms) do
      nil ->
        fun.()

      :infinity ->
        fun.()

      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        run_with_timeout(fun, timeout_ms, opts)

      timeout_ms ->
        {:error,
         Error.validation(
           "runtime budget timeout_ms must be nil, :infinity, or a positive integer",
           source: __MODULE__,
           details: %{timeout_ms: timeout_ms}
         )}
    end
  end

  defp run_with_timeout(fun, timeout_ms, opts) do
    task = Task.async(fn -> safe_call(fun) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:return, {:ok, value}}} ->
        {:ok, value}

      {:ok, {:return, {:error, %Error{} = error}}} ->
        {:error, error}

      {:ok, {:return, other}} ->
        {:error,
         Error.validation("runtime budget function returned an unsupported result",
           source: __MODULE__,
           details: %{result: inspect(other, limit: 20), stage: Keyword.get(opts, :stage)}
         )}

      {:ok, {:exception, exception, stacktrace}} ->
        {:error,
         Error.from_exception(exception,
           source: __MODULE__,
           details: %{
             stage: Keyword.get(opts, :stage),
             stacktrace: Exception.format_stacktrace(stacktrace)
           }
         )}

      {:ok, {:caught, kind, reason}} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           details: %{stage: Keyword.get(opts, :stage), catch_kind: kind}
         )}

      nil ->
        {:error,
         Error.timeout("RLM runtime budget exhausted",
           source: __MODULE__,
           details: %{
             timeout_ms: timeout_ms,
             stage: Keyword.get(opts, :stage),
             objective: Keyword.get(opts, :objective)
           }
         )}
    end
  end

  defp safe_call(fun) do
    {:return, fun.()}
  rescue
    exception ->
      {:exception, exception, __STACKTRACE__}
  catch
    kind, reason ->
      {:caught, kind, reason}
  end
end
