defmodule RunicAI.Harness.Integrated do
  @moduledoc """
  Process-agnostic harness driver for the workflow-owned integrated recipe family.
  """

  @behaviour RunicAI.Harness.Driver

  alias Runic.Workflow
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session
  alias RunicAI.Integrated.RuntimeState
  alias RunicAI.Integrated.Signal
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Trace.Builder
  alias RunicAI.Trace.Sink
  alias RunicAI.Trace.Trajectory

  @impl true
  def new_session(recipe, opts \\ []) when is_atom(recipe) and is_list(opts) do
    policy = Policy.from_input!(Keyword.get(opts, :policy))
    recipe_opts = Keyword.get(opts, :recipe_opts, [])
    snapshot = initial_runtime(recipe, recipe_opts)

    Session.new!(
      :integrated,
      recipe,
      id: Keyword.get(opts, :id),
      driver: __MODULE__,
      snapshot: snapshot,
      metadata: %{
        recipe_opts: recipe_opts,
        driver_kind: :integrated,
        policy: policy,
        metadata: Keyword.get(opts, :metadata, %{})
      },
      trace_sinks: policy.sinks,
      trajectory:
        Trajectory.new!(
          id: Keyword.get(opts, :trajectory_id, "trace:#{System.unique_integer([:positive])}"),
          recipe: recipe,
          session_kind: :integrated,
          metadata: %{recipe_opts: recipe_opts}
        )
    )
  end

  @spec run(module(), term(), keyword()) :: Session.t()
  def run(recipe, input, opts \\ []) do
    recipe
    |> new_session(opts)
    |> submit(input)
    |> drain(Keyword.get(opts, :policy))
  end

  @impl true
  def submit(%Session{} = session, input) do
    Session.enqueue(session, input)
  end

  @impl true
  def advance(%Session{} = session, policy_input \\ nil) do
    policy = effective_policy(session, policy_input)

    case Session.dequeue(session) do
      :empty ->
        session

      {:ok, {input, dequeued_session}} ->
        started_at = System.monotonic_time(:millisecond)

        try do
          signal = normalize_signal_input(input, dequeued_session)
          workflow = run_workflow(dequeued_session, signal, policy)
          output = output_bundle(dequeued_session.recipe, workflow, dequeued_session.snapshot)

          events =
            Builder.events_from_workflow(
              workflow,
              dequeued_session,
              signal,
              output,
              policy,
              elapsed_ms: System.monotonic_time(:millisecond) - started_at
            )

          update_session_from_run(dequeued_session, output, events, policy)
        rescue
          exception ->
            update_failed_session(
              dequeued_session,
              input,
              exception,
              policy,
              System.monotonic_time(:millisecond) - started_at
            )
        catch
          kind, reason ->
            update_failed_session(
              dequeued_session,
              input,
              {kind, reason},
              policy,
              System.monotonic_time(:millisecond) - started_at
            )
        end
    end
  end

  @impl true
  def drain(%Session{} = session, policy_input \\ nil) do
    policy = effective_policy(session, policy_input)
    drain_loop(session, policy, policy.max_reactions, System.monotonic_time(:millisecond))
  end

  @impl true
  def snapshot(%Session{} = session), do: session.snapshot

  @impl true
  def outputs(%Session{} = session), do: session.outputs

  defp drain_loop(%Session{} = session, _policy, 0, _started_at), do: session

  defp drain_loop(%Session{queue: []} = session, _policy, _remaining, _started_at), do: session

  defp drain_loop(%Session{} = session, %Policy{} = policy, remaining, started_at) do
    updated_session = advance(session, policy)

    if stop?(updated_session, policy, started_at) do
      updated_session
    else
      drain_loop(updated_session, policy, remaining - 1, started_at)
    end
  end

  defp run_workflow(%Session{} = session, %Signal{} = signal, %Policy{} = policy) do
    recipe_opts =
      session.metadata
      |> Map.get(:recipe_opts, [])
      |> Keyword.put(:initial_runtime, session.snapshot)

    react_opts = react_opts(policy)

    session.recipe
    |> apply(:new, [recipe_opts])
    |> Workflow.react_until_satisfied(signal, react_opts)
  end

  defp output_bundle(recipe, %Workflow{} = workflow, previous_snapshot) do
    runtime_state =
      invoke_optional(recipe, :runtime_state, [workflow]) ||
        fallback_runtime_state(workflow) ||
        previous_snapshot

    emissions = invoke_optional(recipe, :emissions, [workflow]) || []

    latest_review_request = invoke_optional(recipe, :latest_review_request, [workflow, nil])
    latest_wait = invoke_optional(recipe, :latest_wait, [workflow, nil])
    latest_turn_result = invoke_optional(recipe, :latest_turn_result, [workflow, nil])
    latest_reply_text = invoke_optional(recipe, :latest_reply_text, [workflow, nil])

    %{
      runtime_state: runtime_state,
      emissions: emissions,
      latest_review_request: latest_review_request,
      latest_wait: latest_wait,
      latest_turn_result: latest_turn_result,
      latest_reply_text: latest_reply_text
    }
  end

  defp update_session_from_run(%Session{} = session, output, events, %Policy{} = policy) do
    updated_trajectory =
      session.trajectory
      |> Trajectory.append_events!(events)
      |> Trajectory.record!(
        status: output_status(output),
        final_snapshot: output.runtime_state || session.snapshot,
        outputs: session.outputs ++ [output],
        metadata: session.trajectory.metadata
      )

    updated_sinks =
      Enum.reduce(events, session.trace_sinks, fn event, sinks ->
        case Sink.emit_all(sinks, event) do
          {:ok, next_sinks} -> next_sinks
          {:error, _errors} -> sinks
        end
      end)

    measurements = accumulate_measurements(session.measurements, events)
    next_status = session_status_from_output(output)

    session
    |> Session.with_snapshot(output.runtime_state || session.snapshot)
    |> Session.append_output(output)
    |> Session.with_trajectory(updated_trajectory)
    |> Session.with_measurements(measurements)
    |> Session.with_trace_sinks(updated_sinks)
    |> Session.with_status(next_status)
    |> maybe_flush_sinks(policy)
  end

  defp update_failed_session(%Session{} = session, input, reason, %Policy{} = policy, elapsed_ms) do
    events = Builder.failure_events(session, input, reason, policy, elapsed_ms: elapsed_ms)

    updated_trajectory =
      session.trajectory
      |> Trajectory.append_events!(events)
      |> Trajectory.record!(
        status: :error,
        final_snapshot: session.snapshot,
        outputs: session.outputs,
        metadata: session.trajectory.metadata
      )

    updated_sinks =
      Enum.reduce(events, session.trace_sinks, fn event, sinks ->
        case Sink.emit_all(sinks, event) do
          {:ok, next_sinks} -> next_sinks
          {:error, _errors} -> sinks
        end
      end)

    session
    |> Session.with_trajectory(updated_trajectory)
    |> Session.with_trace_sinks(updated_sinks)
    |> Session.with_status(:error)
    |> maybe_flush_sinks(policy)
  end

  defp effective_policy(%Session{metadata: metadata}, nil) do
    metadata
    |> Map.get(:policy)
    |> Policy.from_input!()
  rescue
    _ -> Policy.new!()
  end

  defp effective_policy(%Session{} = _session, policy_input), do: Policy.from_input!(policy_input)

  defp normalize_signal_input(input, %Session{} = session) do
    default_agent_id =
      case session.snapshot do
        %RuntimeState{metadata: metadata} -> Map.get(metadata, :default_agent_id)
        _ -> nil
      end

    Signal.from_input!(input, default_agent_id: default_agent_id)
  end

  defp invoke_optional(module, function, args) do
    if module_exports?(module, function, length(args)) do
      apply(module, function, args)
    end
  end

  defp fallback_runtime_state(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%RuntimeState{}, &1))
    |> List.last()
  end

  defp react_opts(%Policy{} = policy) do
    []
    |> maybe_put(:async, policy.async)
    |> maybe_put_run_context(policy.run_context)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, false), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_run_context(opts, run_context) when map_size(run_context) == 0, do: opts
  defp maybe_put_run_context(opts, run_context), do: Keyword.put(opts, :run_context, run_context)

  defp initial_runtime(recipe, recipe_opts) do
    cond do
      module_exports?(recipe, :initial_runtime, 1) ->
        apply(recipe, :initial_runtime, [recipe_opts])

      match?(%RuntimeState{}, Keyword.get(recipe_opts, :initial_runtime)) ->
        Keyword.get(recipe_opts, :initial_runtime)

      true ->
        nil
    end
  end

  defp module_exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp accumulate_measurements(current, events) do
    base =
      Map.merge(
        %{
          runs: 0,
          llm_calls: 0,
          tool_calls: 0,
          reviews: 0,
          waits: 0,
          emissions: 0,
          turns: 0,
          elapsed_ms: 0,
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0
        },
        current
      )

    Enum.reduce(events, %{base | runs: base.runs + 1}, fn event, acc ->
      case event.kind do
        :llm_result ->
          usage = event.measurements || %{}

          acc
          |> Map.update!(:llm_calls, &(&1 + 1))
          |> Map.update!(:input_tokens, &(&1 + Map.get(usage, :input_tokens, 0)))
          |> Map.update!(:output_tokens, &(&1 + Map.get(usage, :output_tokens, 0)))
          |> Map.update!(:total_tokens, &(&1 + Map.get(usage, :total_tokens, 0)))

        :tool_result ->
          Map.update!(acc, :tool_calls, &(&1 + 1))

        :review_requested ->
          Map.update!(acc, :reviews, &(&1 + 1))

        :wait_registered ->
          Map.update!(acc, :waits, &(&1 + 1))

        :emission ->
          Map.update!(acc, :emissions, &(&1 + 1))

        :turn_completed ->
          Map.update!(acc, :turns, &(&1 + 1))

        :workflow_quiesced ->
          Map.update!(acc, :elapsed_ms, &(&1 + Map.get(event.measurements, :elapsed_ms, 0)))

        _ ->
          acc
      end
    end)
  end

  defp output_status(%{latest_review_request: %RunicAI.ReviewRequest{}}), do: :review
  defp output_status(%{latest_wait: %RunicAI.Wait{}}), do: :wait
  defp output_status(_output), do: :ok

  defp session_status_from_output(%{latest_review_request: %RunicAI.ReviewRequest{}}), do: :review
  defp session_status_from_output(%{latest_wait: %RunicAI.Wait{}}), do: :waiting

  defp session_status_from_output(%{runtime_state: %RuntimeState{agents: agents}})
       when map_size(agents) > 0 do
    if Enum.all?(agents, fn {_agent_id, session} -> SessionState.terminal?(session) end) do
      :completed
    else
      :idle
    end
  end

  defp session_status_from_output(_output), do: :idle

  defp stop?(%Session{status: :error}, %Policy{}, _started_at), do: true

  defp stop?(%Session{status: :review}, %Policy{} = policy, _started_at),
    do: Policy.stop_on?(policy, :review)

  defp stop?(%Session{status: :waiting}, %Policy{} = policy, _started_at),
    do: Policy.stop_on?(policy, :wait)

  defp stop?(%Session{} = _session, %Policy{max_wall_time_ms: nil}, _started_at), do: false

  defp stop?(%Session{} = _session, %Policy{max_wall_time_ms: max_wall_time_ms}, started_at) do
    System.monotonic_time(:millisecond) - started_at >= max_wall_time_ms
  end

  defp maybe_flush_sinks(%Session{} = session, %Policy{} = policy) do
    if Policy.stop_on?(policy, :error) and session.status == :error do
      case Sink.flush_all(session.trace_sinks) do
        {:ok, flushed_sinks} -> Session.with_trace_sinks(session, flushed_sinks)
        {:error, _errors} -> session
      end
    else
      session
    end
  end
end
