defmodule RunicAI.Terminal.RLMRunner do
  @moduledoc """
  Backend runner for RLM coding-agent terminal execution.

  RLM live stage data is presentation-neutral. This runner converts stages and
  final artifacts into `RunicAI.Terminal.Event` values for CLI/TUI renderers.
  """

  alias RunicAI.Coding.RLM.Agent
  alias RunicAI.Coding.RLM.ObjectiveLoop
  alias RunicAI.Coding.RLM.ObjectiveSession
  alias RunicAI.Agent.CapabilityResolver
  alias RunicAI.Error
  alias RunicAI.Ids
  alias RunicAI.ReviewDecision
  alias RunicAI.Terminal.Event

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    event_sink = Keyword.get(opts, :event_sink, fn _event -> :ok end)
    session_id = Keyword.get(opts, :session_id) || Ids.unique("rlm:cli")
    run_id = Keyword.get(opts, :run_id) || session_id
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    parent = self()
    objective_progress_sink = Keyword.get(opts, :objective_progress_sink)

    emit(event_sink, started_event(session_id, run_id, cwd, opts))

    rlm_opts =
      opts
      |> Keyword.drop([:event_sink, :run_fun])
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:event_sink, fn stage ->
        send(parent, {:runic_ai_terminal_rlm_stage, run_id, stage})
      end)
      |> Keyword.put(:objective_progress_sink, fn progress ->
        safe_call_progress_sink(objective_progress_sink, progress)
        send(parent, {:runic_ai_terminal_objective_loop_progress, run_id, progress})
      end)

    task =
      Task.async(fn ->
        run_fun = Keyword.get(opts, :run_fun) || (&Agent.run/3)

        if Keyword.get(opts, :objective_loop?, false) do
          ObjectiveLoop.run(
            cwd,
            objective,
            Keyword.merge(rlm_opts,
              runner: run_fun,
              max_iterations: Keyword.get(opts, :max_objective_iterations, 3),
              objective_id: run_id
            )
          )
        else
          run_fun.(cwd, objective, rlm_opts)
        end
      end)

    case await_task(task, session_id, run_id, event_sink, deadline(opts)) do
      {:ok, result} ->
        result
        |> result_events(session_id, run_id)
        |> Enum.each(&emit(event_sink, &1))

        {:ok, final_result(result, session_id, run_id)}

      {:error, %Error{} = error} ->
        emit(event_sink, error_event(session_id, run_id, error))
        {:error, error}
    end
  end

  @spec resume_after_review(ObjectiveSession.t(), ReviewDecision.t() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def resume_after_review(%ObjectiveSession{} = session, review_decision, opts \\ [])
      when is_list(opts) do
    event_sink = Keyword.get(opts, :event_sink, fn _event -> :ok end)
    session_id = Keyword.get(opts, :session_id) || session.id
    run_id = Keyword.get(opts, :run_id) || session.id
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    run_fun = Keyword.get(opts, :run_fun) || (&Agent.run/3)
    objective_progress_sink = Keyword.get(opts, :objective_progress_sink)

    emit(event_sink, resume_started_event(session_id, run_id, cwd, session, opts))

    case ObjectiveLoop.resume_after_review(
           cwd,
           session,
           review_decision,
           Keyword.merge(opts,
             runner: run_fun,
             objective_id: run_id,
             session_id: session_id,
             run_id: run_id,
             cwd: cwd,
             objective_progress_sink: fn progress ->
               safe_call_progress_sink(objective_progress_sink, progress)

               progress
               |> objective_progress_event(session_id, run_id)
               |> then(&emit(event_sink, &1))
             end
           )
         ) do
      {:ok, result} ->
        result
        |> result_events(session_id, run_id)
        |> Enum.each(&emit(event_sink, &1))

        {:ok, final_result(result, session_id, run_id)}

      {:error, %Error{} = error} ->
        emit(event_sink, error_event(session_id, run_id, error))
        {:error, error}
    end
  end

  @spec resume_after_budget(ObjectiveSession.t(), ReviewDecision.t() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def resume_after_budget(%ObjectiveSession{} = session, budget_decision, opts \\ [])
      when is_list(opts) do
    event_sink = Keyword.get(opts, :event_sink, fn _event -> :ok end)
    session_id = Keyword.get(opts, :session_id) || session.id
    run_id = Keyword.get(opts, :run_id) || session.id
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    run_fun = Keyword.get(opts, :run_fun) || (&Agent.run/3)
    objective_progress_sink = Keyword.get(opts, :objective_progress_sink)

    emit(event_sink, resume_started_event(session_id, run_id, cwd, session, opts))

    case ObjectiveLoop.resume_after_budget(
           cwd,
           session,
           budget_decision,
           Keyword.merge(opts,
             runner: run_fun,
             objective_id: run_id,
             session_id: session_id,
             run_id: run_id,
             cwd: cwd,
             objective_progress_sink: fn progress ->
               safe_call_progress_sink(objective_progress_sink, progress)

               progress
               |> objective_progress_event(session_id, run_id)
               |> then(&emit(event_sink, &1))
             end
           )
         ) do
      {:ok, result} ->
        result
        |> result_events(session_id, run_id)
        |> Enum.each(&emit(event_sink, &1))

        {:ok, final_result(result, session_id, run_id)}

      {:error, %Error{} = error} ->
        emit(event_sink, error_event(session_id, run_id, error))
        {:error, error}
    end
  end

  defp await_task(%Task{ref: ref} = task, session_id, run_id, event_sink, deadline_ms) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        drain_stage_messages(session_id, run_id, event_sink)
        result

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "RLM terminal runner task exited"
         )}

      {:runic_ai_terminal_rlm_stage, ^run_id, stage} ->
        stage
        |> Event.from_rlm_stage(session_id: session_id, run_id: run_id)
        |> put_event_run_id(run_id)
        |> then(&emit(event_sink, &1))

        await_task(task, session_id, run_id, event_sink, deadline_ms)

      {:runic_ai_terminal_objective_loop_progress, ^run_id, progress} ->
        progress
        |> objective_progress_event(session_id, run_id)
        |> then(&emit(event_sink, &1))

        await_task(task, session_id, run_id, event_sink, deadline_ms)
    after
      25 ->
        if expired?(deadline_ms) do
          Task.shutdown(task, :brutal_kill)

          {:error,
           Error.timeout("RLM terminal runner timed out",
             source: __MODULE__,
             details: %{session_id: session_id, run_id: run_id}
           )}
        else
          await_task(task, session_id, run_id, event_sink, deadline_ms)
        end
    end
  end

  defp drain_stage_messages(session_id, run_id, event_sink) do
    receive do
      {:runic_ai_terminal_rlm_stage, ^run_id, stage} ->
        stage
        |> Event.from_rlm_stage(session_id: session_id, run_id: run_id)
        |> put_event_run_id(run_id)
        |> then(&emit(event_sink, &1))

        drain_stage_messages(session_id, run_id, event_sink)

      {:runic_ai_terminal_objective_loop_progress, ^run_id, progress} ->
        progress
        |> objective_progress_event(session_id, run_id)
        |> then(&emit(event_sink, &1))

        drain_stage_messages(session_id, run_id, event_sink)
    after
      0 -> :ok
    end
  end

  defp final_result(result, session_id, run_id) do
    scorecard = scorecard(result)
    objective_session = objective_session(result)
    decision = objective_decision(result)

    %{
      agent: :rlm,
      status: final_status(scorecard, decision),
      session_id: session_id,
      run_id: run_id,
      result: result,
      scorecard: scorecard,
      objective_session: objective_session,
      objective_decision: decision,
      persistence_ref: field(result, :persistence_ref)
    }
  end

  defp final_status(scorecard, decision) do
    case decision_action(decision) do
      :complete ->
        :ok

      :request_budget_approval ->
        :needs_budget_approval

      :request_review_approval ->
        :review

      :stop_blocked ->
        :blocked

      :stop_failed ->
        :failed

      _other ->
        final_status(scorecard)
    end
  end

  defp final_status(nil), do: :ok

  defp final_status(scorecard) do
    if field(scorecard, :objective_status) in [:objective_satisfied, "objective_satisfied"] do
      :ok
    else
      :blocked
    end
  end

  defp scorecard(result) do
    result = latest_rlm_result(result)

    cond do
      not is_nil(field(result, :objective_scorecard)) ->
        field(result, :objective_scorecard)

      is_map(field(result, :context)) ->
        field(field(result, :context), :scorecards)
        |> case do
          scorecards when is_list(scorecards) -> List.last(scorecards)
          _other -> nil
        end

      true ->
        nil
    end
  end

  defp result_events(result, session_id, run_id) do
    rlm_result = latest_rlm_result(result)

    rlm_result
    |> Event.from_rlm_result(session_id: session_id, run_id: run_id)
    |> Kernel.++(List.wrap(objective_loop_event(result, session_id, run_id)))
    |> Enum.map(&put_event_run_id(&1, run_id))
  end

  defp objective_loop_event(result, session_id, run_id) do
    case {objective_session(result), objective_decision(result)} do
      {%ObjectiveSession{} = session, decision} ->
        Event.new!(:summary,
          session_id: session_id,
          agent: :rlm,
          phase: :objective_loop,
          status: objective_loop_status(decision),
          title: objective_loop_title(decision),
          detail: objective_loop_detail(session, decision),
          data: %{
            run_id: run_id,
            objective_session: ObjectiveSession.summary(session),
            objective_session_state: ObjectiveSession.to_map(session),
            objective_decision: decision,
            objective_iteration_count: length(session.iterations),
            open_tasks: session.open_tasks,
            completed_tasks: session.completed_tasks,
            review_requests: session.review_requests,
            budget_requests: session.budget_requests
          },
          raw: result
        )

      _other ->
        nil
    end
  end

  defp objective_loop_status(%{action: :request_budget_approval}), do: :review
  defp objective_loop_status(%{action: :request_review_approval}), do: :review
  defp objective_loop_status(%{action: :complete}), do: :ok
  defp objective_loop_status(%{action: :stop_failed}), do: :error
  defp objective_loop_status(%{action: :stop_blocked}), do: :blocked
  defp objective_loop_status(_decision), do: :running

  defp objective_loop_title(%{action: :request_budget_approval}),
    do: "Objective budget approval required"

  defp objective_loop_title(%{action: :request_review_approval}),
    do: "Objective review approval required"

  defp objective_loop_title(%{action: :complete}), do: "Objective satisfied"
  defp objective_loop_title(%{action: :stop_failed}), do: "Objective failed"
  defp objective_loop_title(%{action: :stop_blocked}), do: "Objective blocked"
  defp objective_loop_title(_decision), do: "Objective loop updated"

  defp objective_loop_detail(%ObjectiveSession{} = session, decision) do
    action = decision_action(decision)

    [
      "status: #{session.status}",
      "action: #{action}",
      "iterations: #{length(session.iterations)}",
      objective_loop_error_detail(session.latest_error)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp objective_loop_error_detail(%Error{kind: kind, message: message}) do
    "error: #{kind}: #{message}"
  end

  defp objective_loop_error_detail(%{kind: kind, message: message}) do
    "error: #{kind}: #{message}"
  end

  defp objective_loop_error_detail(%{"kind" => kind, "message" => message}) do
    "error: #{kind}: #{message}"
  end

  defp objective_loop_error_detail(_error), do: nil

  defp objective_progress_event(progress, session_id, run_id) when is_map(progress) do
    event = field(progress, :event)

    Event.new!(:summary,
      session_id: session_id,
      agent: :rlm,
      phase: :objective_loop_progress,
      status: objective_progress_status(progress),
      title: objective_progress_title(event),
      detail: objective_progress_detail(progress),
      data: put_run_id(progress, run_id),
      raw: progress
    )
  end

  defp objective_progress_status(progress) do
    case field(progress, :action) do
      :complete -> :ok
      "complete" -> :ok
      :request_budget_approval -> :review
      "request_budget_approval" -> :review
      :request_review_approval -> :review
      "request_review_approval" -> :review
      :stop_blocked -> :blocked
      "stop_blocked" -> :blocked
      :stop_failed -> :error
      "stop_failed" -> :error
      _other -> :running
    end
  end

  defp objective_progress_title(:iteration_started), do: "Objective iteration started"
  defp objective_progress_title("iteration_started"), do: "Objective iteration started"
  defp objective_progress_title(:iteration_completed), do: "Objective iteration completed"
  defp objective_progress_title("iteration_completed"), do: "Objective iteration completed"
  defp objective_progress_title(:iteration_error), do: "Objective iteration errored"
  defp objective_progress_title("iteration_error"), do: "Objective iteration errored"
  defp objective_progress_title(:review_completed), do: "Objective review completed"
  defp objective_progress_title("review_completed"), do: "Objective review completed"
  defp objective_progress_title(_event), do: "Objective loop progress"

  defp objective_progress_detail(progress) do
    status = field(progress, :status)
    action = field(progress, :action)
    iteration = field(progress, :current_iteration) || field(progress, :iteration_count)
    "status: #{status}, action: #{action || "continue"}, iteration: #{iteration}"
  end

  defp latest_rlm_result(result) do
    case field(result, :latest_result) do
      latest when is_map(latest) -> latest
      _other -> result
    end
  end

  defp objective_session(result) do
    case field(result, :session) do
      %ObjectiveSession{} = session -> session
      _other -> nil
    end
  end

  defp objective_decision(result) do
    case field(result, :decision) do
      decision when is_map(decision) -> decision
      _other -> nil
    end
  end

  defp decision_action(decision), do: field(decision, :action)

  defp started_event(session_id, run_id, cwd, opts) do
    Event.new!(:status,
      session_id: session_id,
      agent: :rlm,
      phase: :session,
      status: :running,
      title: "RLM agent started",
      detail: cwd,
      data: %{
        run_id: run_id,
        cwd: cwd,
        model: Keyword.get(opts, :model),
        client: Keyword.get(opts, :client),
        client_label: Keyword.get(opts, :client_label),
        model_resolution: Keyword.get(opts, :model_resolution),
        capability_profile:
          CapabilityResolver.snapshot_for_launch(cwd, Keyword.put(opts, :agent, :rlm))
      }
    )
  end

  defp error_event(session_id, run_id, %Error{} = error) do
    Event.new!(:error,
      session_id: session_id,
      agent: :rlm,
      phase: :run,
      status: :error,
      title: "RLM agent failed",
      detail: error.message,
      data: %{run_id: run_id, error: error},
      raw: error
    )
  end

  defp resume_started_event(session_id, run_id, cwd, %ObjectiveSession{} = session, opts) do
    Event.new!(:status,
      session_id: session_id,
      agent: :rlm,
      phase: :objective_loop_resume,
      status: :running,
      title: "RLM objective resume started",
      detail: cwd,
      data: %{
        run_id: run_id,
        cwd: cwd,
        objective_session_id: session.id,
        objective_status: session.status,
        model: Keyword.get(opts, :model),
        client: Keyword.get(opts, :client),
        capability_profile:
          CapabilityResolver.snapshot_for_launch(cwd, Keyword.put(opts, :agent, :rlm))
      }
    )
  end

  defp put_event_run_id(%Event{} = event, run_id) do
    %{event | data: put_run_id(event.data, run_id)}
  end

  defp put_run_id(data, run_id) do
    data
    |> Kernel.||(%{})
    |> Map.put(:run_id, run_id)
    |> Map.put("run_id", run_id)
  end

  defp deadline(opts) do
    case Keyword.get(opts, :max_runtime_ms) do
      value when is_integer(value) and value > 0 ->
        System.monotonic_time(:millisecond) + value + 1_000

      _other ->
        nil
    end
  end

  defp expired?(nil), do: false
  defp expired?(deadline_ms), do: System.monotonic_time(:millisecond) > deadline_ms

  defp emit(event_sink, %Event{} = event) do
    try do
      event_sink.(event)
    rescue
      _exception -> :ok
    end

    :ok
  end

  defp safe_call_progress_sink(nil, _progress), do: :ok

  defp safe_call_progress_sink(sink, progress) when is_function(sink, 1) do
    try do
      sink.(progress)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  defp safe_call_progress_sink(_sink, _progress), do: :ok

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
