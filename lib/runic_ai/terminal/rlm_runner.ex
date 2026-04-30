defmodule RunicAI.Terminal.RLMRunner do
  @moduledoc """
  Backend runner for RLM coding-agent terminal execution.

  RLM live stage data is presentation-neutral. This runner converts stages and
  final artifacts into `RunicAI.Terminal.Event` values for CLI/TUI renderers.
  """

  alias RunicAI.Coding.RLM.Agent
  alias RunicAI.Error
  alias RunicAI.Terminal.Event

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    event_sink = Keyword.get(opts, :event_sink, fn _event -> :ok end)
    session_id = Keyword.get(opts, :session_id) || "rlm:cli:#{System.unique_integer([:positive])}"
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    parent = self()

    emit(event_sink, started_event(session_id, cwd, opts))

    rlm_opts =
      opts
      |> Keyword.drop([:event_sink, :run_fun])
      |> Keyword.put(:run_id, session_id)
      |> Keyword.put(:event_sink, fn stage ->
        send(parent, {:runic_ai_terminal_rlm_stage, session_id, stage})
      end)

    task =
      Task.async(fn ->
        run_fun = Keyword.get(opts, :run_fun, &Agent.run/3)
        run_fun.(cwd, objective, rlm_opts)
      end)

    case await_task(task, session_id, event_sink, deadline(opts)) do
      {:ok, result} ->
        Event.from_rlm_result(result, session_id: session_id)
        |> Enum.each(&emit(event_sink, &1))

        {:ok, final_result(result, session_id)}

      {:error, %Error{} = error} ->
        emit(event_sink, error_event(session_id, error))
        {:error, error}
    end
  end

  defp await_task(%Task{ref: ref} = task, session_id, event_sink, deadline_ms) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        drain_stage_messages(session_id, event_sink)
        result

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "RLM terminal runner task exited"
         )}

      {:runic_ai_terminal_rlm_stage, ^session_id, stage} ->
        emit(event_sink, Event.from_rlm_stage(stage, session_id: session_id))
        await_task(task, session_id, event_sink, deadline_ms)
    after
      25 ->
        if expired?(deadline_ms) do
          Task.shutdown(task, :brutal_kill)

          {:error,
           Error.timeout("RLM terminal runner timed out",
             source: __MODULE__,
             details: %{session_id: session_id}
           )}
        else
          await_task(task, session_id, event_sink, deadline_ms)
        end
    end
  end

  defp drain_stage_messages(session_id, event_sink) do
    receive do
      {:runic_ai_terminal_rlm_stage, ^session_id, stage} ->
        emit(event_sink, Event.from_rlm_stage(stage, session_id: session_id))
        drain_stage_messages(session_id, event_sink)
    after
      0 -> :ok
    end
  end

  defp final_result(result, session_id) do
    scorecard = scorecard(result)

    %{
      agent: :rlm,
      status: final_status(scorecard),
      session_id: session_id,
      run_id: session_id,
      result: result,
      scorecard: scorecard,
      persistence_ref: field(result, :persistence_ref)
    }
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

  defp started_event(session_id, cwd, opts) do
    Event.new!(:status,
      session_id: session_id,
      agent: :rlm,
      phase: :session,
      status: :running,
      title: "RLM agent started",
      detail: cwd,
      data: %{cwd: cwd, model: Keyword.get(opts, :model), client: Keyword.get(opts, :client)}
    )
  end

  defp error_event(session_id, %Error{} = error) do
    Event.new!(:error,
      session_id: session_id,
      agent: :rlm,
      phase: :run,
      status: :error,
      title: "RLM agent failed",
      detail: error.message,
      data: %{error: error},
      raw: error
    )
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

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
