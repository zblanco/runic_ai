defmodule RunicAI.Coding.RLM.ObjectiveLoop do
  @moduledoc """
  Multi-workflow objective loop for RLM coding agents.

  The loop is intentionally small: it delegates each workflow attempt to a
  runner, records the result in `ObjectiveSession`, and continues only while
  the session has a concrete next objective and remaining iteration budget.
  Budget exhaustion is returned as a reviewable decision so UI, CLI, and TUI
  clients can ask the operator whether to approve more budget.
  """

  alias RunicAI.Coding.RLM.Agent
  alias RunicAI.Coding.RLM.ObjectiveSession
  alias RunicAI.Error
  alias RunicAI.ReviewDecision

  @type result :: %{
          required(:session) => ObjectiveSession.t(),
          required(:decision) => ObjectiveSession.decision(),
          optional(:latest_result) => map(),
          optional(:latest_error) => Error.t()
        }

  @spec run(term(), String.t(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def run(workspace_input, objective, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    opts = put_loop_deadline(opts)

    session_opts =
      opts
      |> Keyword.take([:id, :max_iterations, :metadata])
      |> Keyword.update(:metadata, loop_runtime_metadata(opts), fn metadata ->
        Map.merge(normalize_map(metadata), loop_runtime_metadata(opts))
      end)
      |> Keyword.put_new(:id, Keyword.get(opts, :objective_id))

    with {:ok, session} <- ObjectiveSession.new(objective, session_opts) do
      runner = Keyword.get(opts, :runner, &Agent.run/3)
      loop(workspace_input, session, runner, opts)
    end
  end

  @spec resume_after_review(term(), ObjectiveSession.t(), ReviewDecision.t() | map(), keyword()) ::
          {:ok, result()} | {:error, Error.t()}
  def resume_after_review(
        workspace_input,
        %ObjectiveSession{} = session,
        review_decision,
        opts \\ []
      )
      when is_list(opts) do
    opts = put_loop_deadline(opts, session)

    with {:ok, session} <- ObjectiveSession.record_review_decision(session, review_decision, opts) do
      if ObjectiveSession.terminal?(session) do
        {:ok,
         %{
           session: session,
           decision: ObjectiveSession.decision(session),
           latest_result: session.latest_result,
           latest_error: session.latest_error
         }}
      else
        runner = Keyword.get(opts, :runner, &Agent.run/3)
        loop(workspace_input, session, runner, opts)
      end
    end
  end

  @spec resume_after_budget(term(), ObjectiveSession.t(), ReviewDecision.t() | map(), keyword()) ::
          {:ok, result()} | {:error, Error.t()}
  def resume_after_budget(
        workspace_input,
        %ObjectiveSession{} = session,
        budget_decision,
        opts \\ []
      )
      when is_list(opts) do
    with {:ok, session} <- ObjectiveSession.record_budget_decision(session, budget_decision, opts) do
      opts = put_loop_deadline(opts, session)

      if ObjectiveSession.terminal?(session) do
        {:ok,
         %{
           session: session,
           decision: ObjectiveSession.decision(session),
           latest_result: session.latest_result,
           latest_error: session.latest_error
         }}
      else
        runner = Keyword.get(opts, :runner, &Agent.run/3)
        loop(workspace_input, session, runner, opts)
      end
    end
  end

  defp loop(workspace_input, %ObjectiveSession{} = session, runner, opts) do
    if loop_deadline_expired?(opts) do
      session = ObjectiveSession.record_error(session, objective_timeout_error(session, opts))
      decision = ObjectiveSession.decision(session)
      emit_progress(opts, :iteration_error, session, decision)
      {:ok, result(session, decision)}
    else
      session = ObjectiveSession.iteration_started(session)
      emit_progress(opts, :iteration_started, session)
      objective = ObjectiveSession.next_workflow_objective(session)
      runner_opts = runner_opts(session, opts)

      session =
        case call_runner(runner, workspace_input, objective, runner_opts) do
          {:ok, result} -> ObjectiveSession.record_result(session, result)
          {:error, error} -> ObjectiveSession.record_error(session, error)
        end

      decision = ObjectiveSession.decision(session)
      emit_progress(opts, latest_progress_event(session), session, decision)

      if decision.action == :continue and not ObjectiveSession.terminal?(session) do
        loop(workspace_input, session, runner, opts)
      else
        {:ok, result(session, decision)}
      end
    end
  end

  defp call_runner(runner, workspace_input, objective, opts) when is_function(runner, 3) do
    runner.(workspace_input, objective, opts)
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  catch
    kind, reason ->
      {:error,
       Error.from_reason(reason,
         source: __MODULE__,
         details: %{catch_kind: kind}
       )}
  end

  defp runner_opts(%ObjectiveSession{} = session, opts) do
    opts
    |> Keyword.drop([:runner, :objective_id, :max_iterations, :objective_progress_sink])
    |> Keyword.put(:objective_session_id, session.id)
    |> Keyword.put(:objective_iteration, length(session.iterations) + 1)
    |> Keyword.put(:original_objective, session.objective)
    |> put_remaining_runtime_budget()
  end

  defp result(%ObjectiveSession{} = session, decision) do
    %{
      session: session,
      decision: decision,
      latest_result: session.latest_result,
      latest_error: session.latest_error
    }
  end

  defp latest_progress_event(%ObjectiveSession{progress_log: []}), do: :iteration_completed

  defp latest_progress_event(%ObjectiveSession{progress_log: progress_log}) do
    progress_log
    |> List.last()
    |> case do
      %{event: event} -> event
      %{"event" => event} -> event
      _other -> :iteration_completed
    end
  end

  defp emit_progress(opts, event, %ObjectiveSession{} = session, decision \\ nil) do
    case Keyword.get(opts, :objective_progress_sink) do
      sink when is_function(sink, 1) ->
        safe_call_progress_sink(sink, objective_progress(event, session, decision, opts))

      _other ->
        :ok
    end
  end

  defp objective_progress(event, %ObjectiveSession{} = session, decision, opts) do
    %{
      stage: :objective_loop,
      event: event,
      status: session.status,
      action: decision && Map.get(decision, :action),
      objective_session_id: session.id,
      objective: session.objective,
      next_objective: session.next_objective,
      current_iteration: current_iteration(event, session),
      iteration_count: length(session.iterations),
      max_iterations: session.max_iterations,
      run_deadline_ms: Keyword.get(opts, :run_deadline_ms),
      remaining_runtime_ms: remaining_runtime_ms(opts),
      open_tasks: session.open_tasks,
      completed_tasks: session.completed_tasks,
      review_requests: session.review_requests,
      budget_requests: session.budget_requests,
      objective_session: ObjectiveSession.summary(session),
      objective_session_state: ObjectiveSession.to_map(session)
    }
    |> reject_nil_values()
  end

  defp current_iteration(event, %ObjectiveSession{} = session)
       when event in [:iteration_started, "iteration_started"],
       do: length(session.iterations) + 1

  defp current_iteration(_event, %ObjectiveSession{} = session),
    do: max(length(session.iterations), 1)

  defp safe_call_progress_sink(sink, event) do
    sink.(event)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp put_loop_deadline(opts, session \\ nil) do
    case {Keyword.get(opts, :run_deadline_ms), Keyword.get(opts, :max_runtime_ms)} do
      {deadline_ms, _max_runtime_ms} when is_integer(deadline_ms) ->
        opts

      {_deadline_ms, _max_runtime_ms} ->
        case session_deadline(session) do
          deadline_ms when is_integer(deadline_ms) ->
            Keyword.put(opts, :run_deadline_ms, deadline_ms)

          _other ->
            put_new_loop_deadline(opts)
        end
    end
  end

  defp put_new_loop_deadline(opts) do
    case Keyword.get(opts, :max_runtime_ms) do
      max_runtime_ms when is_integer(max_runtime_ms) and max_runtime_ms > 0 ->
        Keyword.put(opts, :run_deadline_ms, System.monotonic_time(:millisecond) + max_runtime_ms)

      _other ->
        opts
    end
  end

  defp session_deadline(%ObjectiveSession{metadata: metadata}) when is_map(metadata) do
    case field(metadata, :run_deadline_ms) do
      deadline_ms when is_integer(deadline_ms) -> deadline_ms
      deadline_ms when is_binary(deadline_ms) -> parse_positive_integer(deadline_ms)
      _other -> nil
    end
  end

  defp session_deadline(_session), do: nil

  defp loop_runtime_metadata(opts) do
    %{}
    |> maybe_put_metadata(:run_deadline_ms, Keyword.get(opts, :run_deadline_ms))
    |> maybe_put_metadata(:max_runtime_ms, Keyword.get(opts, :max_runtime_ms))
  end

  defp put_remaining_runtime_budget(opts) do
    case remaining_runtime_ms(opts) do
      remaining_ms when is_integer(remaining_ms) and remaining_ms > 0 ->
        Keyword.put(opts, :max_runtime_ms, remaining_ms)

      _other ->
        opts
    end
  end

  defp loop_deadline_expired?(opts) do
    case Keyword.get(opts, :run_deadline_ms) do
      deadline_ms when is_integer(deadline_ms) ->
        System.monotonic_time(:millisecond) >= deadline_ms

      _other ->
        false
    end
  end

  defp remaining_runtime_ms(opts) do
    case Keyword.get(opts, :run_deadline_ms) do
      deadline_ms when is_integer(deadline_ms) ->
        max(deadline_ms - System.monotonic_time(:millisecond), 0)

      _other ->
        nil
    end
  end

  defp objective_timeout_error(%ObjectiveSession{} = session, opts) do
    Error.timeout("RLM objective-loop runtime budget exhausted",
      source: __MODULE__,
      details: %{
        stage: :objective_loop,
        objective_session_id: session.id,
        iteration_count: length(session.iterations),
        max_iterations: session.max_iterations,
        run_deadline_ms: Keyword.get(opts, :run_deadline_ms)
      }
    )
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(list) when is_list(list), do: Map.new(list)
  defp normalize_map(_other), do: %{}

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end
end
