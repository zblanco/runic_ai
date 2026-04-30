defmodule RunicAI.Terminal.StandardRunner do
  @moduledoc """
  Backend runner for the standard coding agent terminal harness.

  This module owns runtime/session execution and emits normalized terminal
  events through a callback. It does not print, prompt, or know about Mix.
  """

  alias RunicAI.Coding.Review
  alias RunicAI.Coding.Session, as: CodingSession
  alias RunicAI.Error
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session
  alias RunicAI.ReviewRequest
  alias RunicAI.Runtime
  alias RunicAI.Terminal.Event

  @default_max_review_cycles 20

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    event_sink = Keyword.get(opts, :event_sink, fn _event -> :ok end)
    review_decider = Keyword.get(opts, :review_decider, &default_review_decider/2)

    session_id =
      Keyword.get(opts, :session_id) || "coding:cli:#{System.unique_integer([:positive])}"

    cwd = Keyword.get(opts, :cwd, File.cwd!())
    policy = policy(opts)

    spec_opts =
      [
        id: session_id,
        policy: policy,
        mode: Keyword.get(opts, :mode, :verify),
        objective_gate?: Keyword.get(opts, :objective_gate?, true)
      ]
      |> put_present(:model, Keyword.get(opts, :model))
      |> put_present(:client, Keyword.get(opts, :client))
      |> put_present(:max_turns, Keyword.get(opts, :max_turns))
      |> put_present(:max_elapsed_ms, Keyword.get(opts, :max_runtime_ms))

    spec = CodingSession.spec(cwd, spec_opts)

    with {:ok, handle} <- Runtime.start_session(spec),
         :ok <- Runtime.subscribe(handle) do
      emit(event_sink, started_event(session_id, cwd, opts))

      try do
        do_run(handle, objective, session_id, opts, event_sink, review_decider, 0)
      after
        unless Keyword.get(opts, :keep_session?, false) do
          Runtime.stop(handle)
        end
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  @spec latest_review_request(Session.t()) :: ReviewRequest.t() | nil
  def latest_review_request(%Session{outputs: outputs}) do
    outputs
    |> Enum.reverse()
    |> Enum.find_value(fn output ->
      field(output, :latest_review_request) || field(output, :review_request)
    end)
  end

  defp do_run(handle, input, session_id, opts, event_sink, review_decider, review_cycles) do
    with {:ok, session} <- submit_and_drain(handle, input, session_id, opts, event_sink) do
      cond do
        session.status == :review and
            review_cycles >= Keyword.get(opts, :max_review_cycles, @default_max_review_cycles) ->
          {:error,
           Error.validation("standard terminal runner exceeded review cycle budget",
             source: __MODULE__,
             details: %{session_id: session_id, max_review_cycles: review_cycles}
           )}

        session.status == :review ->
          continue_after_review(
            handle,
            session,
            session_id,
            opts,
            event_sink,
            review_decider,
            review_cycles
          )

        true ->
          {:ok, final_result(session)}
      end
    end
  end

  defp continue_after_review(
         handle,
         %Session{} = session,
         session_id,
         opts,
         event_sink,
         review_decider,
         review_cycles
       ) do
    case latest_review_request(session) do
      %ReviewRequest{} = request ->
        emit(
          event_sink,
          Event.from_review_request(request, session_id: session_id, agent: :standard)
        )

        case review_decider.(request, %{session: session, session_id: session_id, handle: handle}) do
          {:ok, decision} ->
            do_run(
              handle,
              decision,
              session_id,
              opts,
              event_sink,
              review_decider,
              review_cycles + 1
            )

          {:error, %Error{} = error} ->
            {:error, error}

          {:error, reason} ->
            {:error, Error.from_reason(reason, source: __MODULE__)}
        end

      nil ->
        {:error,
         Error.validation("standard terminal runner entered review without a review request",
           source: __MODULE__,
           details: %{session_id: session_id}
         )}
    end
  end

  defp submit_and_drain(handle, input, session_id, opts, event_sink) do
    task =
      Task.async(fn ->
        with {:ok, _queued} <- Runtime.submit(handle, input) do
          Runtime.drain(handle)
        end
      end)

    await_task(task, session_id, event_sink, deadline(opts))
  end

  defp await_task(%Task{ref: ref} = task, session_id, event_sink, deadline_ms) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        drain_runtime_messages(session_id, event_sink)
        result

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "standard terminal runner task exited"
         )}

      {:runic_ai_runtime, ^session_id, _kind, _payload} = message ->
        emit_runtime_message(event_sink, message)
        await_task(task, session_id, event_sink, deadline_ms)
    after
      25 ->
        if expired?(deadline_ms) do
          Task.shutdown(task, :brutal_kill)

          {:error,
           Error.timeout("standard terminal runner timed out",
             source: __MODULE__,
             details: %{session_id: session_id}
           )}
        else
          await_task(task, session_id, event_sink, deadline_ms)
        end
    end
  end

  defp drain_runtime_messages(session_id, event_sink) do
    receive do
      {:runic_ai_runtime, ^session_id, _kind, _payload} = message ->
        emit_runtime_message(event_sink, message)
        drain_runtime_messages(session_id, event_sink)
    after
      0 -> :ok
    end
  end

  defp emit_runtime_message(event_sink, message) do
    message
    |> Event.from_runtime_message(agent: :standard)
    |> Enum.each(&emit(event_sink, &1))
  end

  defp final_result(%Session{} = session) do
    snapshot = CodingSession.snapshot(session)

    %{
      agent: :standard,
      status: session.status,
      session_id: session.id,
      session: session,
      snapshot: snapshot,
      summary: snapshot.summary,
      outputs: session.outputs,
      trajectory: session.trajectory
    }
  end

  defp started_event(session_id, cwd, opts) do
    Event.new!(:status,
      session_id: session_id,
      agent: :standard,
      phase: :session,
      status: :running,
      title: "Standard agent started",
      detail: cwd,
      data: %{
        cwd: cwd,
        mode: Keyword.get(opts, :mode, :verify),
        model: Keyword.get(opts, :model),
        client: Keyword.get(opts, :client)
      }
    )
  end

  defp policy(opts) do
    Policy.new!(
      max_turns: Keyword.get(opts, :max_turns),
      max_wall_time_ms: Keyword.get(opts, :max_runtime_ms),
      stop_on: [:review, :wait, :error],
      capture_policy: [mode: :summary]
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

  defp default_review_decider(%ReviewRequest{} = request, _context) do
    {:ok, Review.deny(request, reason: "terminal runner has no review decider")}
  end

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

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)
end
