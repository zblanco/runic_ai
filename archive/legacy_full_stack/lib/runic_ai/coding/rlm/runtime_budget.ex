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
    started_ms = System.monotonic_time(:millisecond)

    await_task(task, timeout_ms, started_ms, opts)
  end

  defp await_task(task, timeout_ms, started_ms, opts) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_ms
    remaining_ms = timeout_ms - elapsed_ms

    if remaining_ms <= 0 do
      Task.shutdown(task, :brutal_kill)
      timeout_error(timeout_ms, opts)
    else
      interval_ms = min(progress_tick_ms(opts), remaining_ms)

      case Task.yield(task, interval_ms) do
        nil ->
          emit_progress_tick(timeout_ms, started_ms, opts)
          await_task(task, timeout_ms, started_ms, opts)

        result ->
          handle_task_result(result, timeout_ms, opts)
      end
    end
  end

  defp handle_task_result(result, timeout_ms, opts) do
    case result do
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
        timeout_error(timeout_ms, opts)
    end
  end

  defp timeout_error(timeout_ms, opts) do
    details =
      %{
        timeout_ms: timeout_ms,
        stage: Keyword.get(opts, :stage),
        objective: Keyword.get(opts, :objective)
      }
      |> Map.merge(timeout_details(opts))

    case Keyword.get(opts, :timeout_handler) do
      handler when is_function(handler, 1) ->
        handler.(details)

      _other ->
        {:error,
         Error.timeout("RLM runtime budget exhausted",
           source: __MODULE__,
           details: details
         )}
    end
  rescue
    exception ->
      {:error,
       Error.from_exception(exception,
         source: __MODULE__,
         details: %{timeout_ms: timeout_ms, stage: Keyword.get(opts, :stage)}
       )}
  end

  defp progress_tick_ms(opts) do
    case Keyword.get(opts, :tick_ms, 5_000) do
      tick_ms when is_integer(tick_ms) and tick_ms > 0 -> tick_ms
      _other -> 5_000
    end
  end

  defp emit_progress_tick(timeout_ms, started_ms, opts) do
    case Keyword.get(opts, :progress_sink) do
      sink when is_function(sink, 1) ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_ms

        sink.(%{
          timeout_ms: timeout_ms,
          elapsed_ms: elapsed_ms,
          remaining_ms: max(timeout_ms - elapsed_ms, 0),
          stage: Keyword.get(opts, :stage),
          objective: Keyword.get(opts, :objective)
        })

        :ok

      _other ->
        :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp timeout_details(opts) do
    case Keyword.get(opts, :details, %{}) do
      details when is_map(details) ->
        details

      details when is_list(details) ->
        Map.new(details)

      _other ->
        %{}
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
