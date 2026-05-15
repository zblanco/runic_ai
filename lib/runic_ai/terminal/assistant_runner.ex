defmodule RunicAI.Terminal.AssistantRunner do
  @moduledoc """
  Backend runner for the general-purpose assistant RLM terminal route.
  """

  alias RunicAI.Assistant.RLM.Agent
  alias RunicAI.Error
  alias RunicAI.Ids
  alias RunicAI.Terminal.Event

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    event_sink = Keyword.get(opts, :event_sink, fn _event -> :ok end)

    session_id =
      Keyword.get(opts, :session_id) || Ids.unique("assistant:cli")

    run_id = Keyword.get(opts, :run_id) || session_id
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    parent = self()

    emit(event_sink, started_event(session_id, run_id, cwd, opts))

    agent_opts =
      opts
      |> Keyword.drop([:event_sink, :run_fun])
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:event_sink, fn stage ->
        send(parent, {:runic_ai_terminal_assistant_stage, run_id, stage})
      end)

    task =
      Task.async(fn ->
        run_fun = Keyword.get(opts, :run_fun, &Agent.run/3)
        run_fun.(cwd, objective, agent_opts)
      end)

    case await_task(task, session_id, run_id, event_sink, deadline(opts)) do
      {:ok, result} ->
        Event.from_rlm_result(result, session_id: session_id, agent: :assistant)
        |> Enum.map(&put_event_run_id(&1, run_id))
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
           message: "assistant terminal runner task exited"
         )}

      {:runic_ai_terminal_assistant_stage, ^run_id, stage} ->
        stage
        |> Event.from_rlm_stage(session_id: session_id, agent: :assistant)
        |> put_event_run_id(run_id)
        |> then(&emit(event_sink, &1))

        await_task(task, session_id, run_id, event_sink, deadline_ms)
    after
      25 ->
        if expired?(deadline_ms) do
          Task.shutdown(task, :brutal_kill)

          {:error,
           Error.timeout("assistant terminal runner timed out",
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
      {:runic_ai_terminal_assistant_stage, ^run_id, stage} ->
        stage
        |> Event.from_rlm_stage(session_id: session_id, agent: :assistant)
        |> put_event_run_id(run_id)
        |> then(&emit(event_sink, &1))

        drain_stage_messages(session_id, run_id, event_sink)
    after
      0 -> :ok
    end
  end

  defp final_result(result, session_id, run_id) do
    scorecard = scorecard(result)

    %{
      agent: :assistant,
      status: final_status(scorecard),
      session_id: session_id,
      run_id: run_id,
      result: result,
      scorecard: scorecard,
      artifacts: Map.get(result, :artifacts, []),
      repair_history: Map.get(result, :repair_history, [])
    }
  end

  defp final_status(%{objective_status: status})
       when status in [:objective_satisfied, "objective_satisfied"],
       do: :ok

  defp final_status(%{objective_status: status})
       when status in [:objective_incomplete, "objective_incomplete"],
       do: :blocked

  defp final_status(_scorecard), do: :ok

  defp scorecard(result) do
    Map.get(result, :scorecard) ||
      Map.get(result, :objective_scorecard) ||
      Map.get(result, "scorecard") ||
      Map.get(result, "objective_scorecard")
  end

  defp started_event(session_id, run_id, cwd, opts) do
    Event.new!(:status,
      session_id: session_id,
      agent: :assistant,
      phase: :session,
      status: :running,
      title: "Assistant RLM agent started",
      detail: cwd,
      data: %{
        run_id: run_id,
        cwd: cwd,
        model: Keyword.get(opts, :model),
        client: Keyword.get(opts, :client),
        inputs: Keyword.get(opts, :input_paths, []),
        output: Keyword.get(opts, :output_path)
      }
    )
  end

  defp error_event(session_id, run_id, %Error{} = error) do
    artifact_outcome = Event.artifact_outcome_from_error(error)

    Event.new!(:error,
      session_id: session_id,
      agent: :assistant,
      phase: :run,
      status: :error,
      title: "Assistant RLM agent failed",
      detail: error.message,
      data:
        %{run_id: run_id, error: error}
        |> maybe_put(:artifact_outcome, artifact_outcome)
        |> maybe_put(:suggested_paths, suggested_paths(artifact_outcome)),
      raw: error
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp suggested_paths(nil), do: nil
  defp suggested_paths(%{suggested_paths: paths}) when is_list(paths), do: paths
  defp suggested_paths(%{"suggested_paths" => paths}) when is_list(paths), do: paths
  defp suggested_paths(_outcome), do: nil

  defp put_event_run_id(%Event{} = event, run_id) do
    %{event | data: Map.put_new(event.data || %{}, :run_id, run_id)}
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
end
