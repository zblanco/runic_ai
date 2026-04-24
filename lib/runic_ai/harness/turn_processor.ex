defmodule RunicAI.Harness.TurnProcessor do
  @moduledoc """
  Process-agnostic harness driver for the external-state recipe family.
  """

  @behaviour RunicAI.Harness.Driver

  alias Runic.Workflow
  alias RunicAI.Agent.State
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session
  alias RunicAI.Trace.Builder
  alias RunicAI.Trace.Sink
  alias RunicAI.Trace.Trajectory

  @impl true
  def new_session(recipe, opts \\ []) when is_atom(recipe) and is_list(opts) do
    policy = Policy.from_input!(Keyword.get(opts, :policy))
    recipe_opts = Keyword.get(opts, :recipe_opts, [])
    snapshot = initial_snapshot(recipe, recipe_opts)

    Session.new!(
      :turn_processor,
      recipe,
      id: Keyword.get(opts, :id),
      driver: __MODULE__,
      snapshot: snapshot,
      metadata: %{
        recipe_opts: recipe_opts,
        driver_kind: :turn_processor,
        policy: policy,
        metadata: Keyword.get(opts, :metadata, %{})
      },
      trace_sinks: policy.sinks,
      trajectory:
        Trajectory.new!(
          id: Keyword.get(opts, :trajectory_id, "trace:#{System.unique_integer([:positive])}"),
          recipe: recipe,
          session_kind: :turn_processor,
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
          workflow = run_workflow(dequeued_session, input, policy)
          output = output_bundle(dequeued_session.recipe, workflow, dequeued_session.snapshot)

          events =
            Builder.events_from_workflow(
              workflow,
              dequeued_session,
              input,
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

  defp run_workflow(%Session{} = session, input, %Policy{} = policy) do
    recipe = session.recipe
    recipe_opts = session_recipe_opts(session, policy)
    normalized_input = normalize_turn_input(input, session.snapshot)
    react_opts = react_opts(policy)

    if module_exports?(recipe, :react_until_resolution, 3) do
      apply(recipe, :react_until_resolution, [recipe_opts, normalized_input, react_opts])
    else
      recipe
      |> apply(:new, [recipe_opts])
      |> Workflow.react_until_satisfied(normalized_input, react_opts)
    end
  end

  defp output_bundle(recipe, %Workflow{} = workflow, previous_snapshot) do
    state =
      invoke_optional(recipe, :latest_state, [workflow]) || fallback_state(workflow) ||
        previous_snapshot

    turn_result =
      invoke_optional(recipe, :latest_turn_result, [workflow]) ||
        latest_struct(workflow, RunicAI.Agent.TurnResult)

    continue_decision =
      invoke_optional(recipe, :latest_continue_decision, [workflow]) ||
        latest_struct(workflow, RunicAI.Agent.ContinueDecision)

    review_request =
      invoke_optional(recipe, :latest_review_request, [workflow]) ||
        latest_struct(workflow, RunicAI.ReviewRequest)

    wait =
      invoke_optional(recipe, :latest_wait, [workflow]) || latest_struct(workflow, RunicAI.Wait)

    selection =
      invoke_optional(recipe, :latest_selection, [workflow]) ||
        latest_struct(workflow, RunicAI.Tool.Selection)

    execution_plan =
      invoke_optional(recipe, :latest_execution_plan, [workflow]) ||
        latest_struct(workflow, RunicAI.Tool.ExecutionPlan)

    tool_results =
      invoke_optional(recipe, :latest_tool_results, [workflow]) ||
        latest_tool_results(workflow)

    reply_text = invoke_optional(recipe, :latest_reply_text, [workflow])

    %{
      state: state,
      turn_result: turn_result,
      continue_decision: continue_decision,
      review_request: review_request,
      wait: wait,
      selection: selection,
      execution_plan: execution_plan,
      tool_results: tool_results,
      reply_text: reply_text
    }
  end

  defp update_session_from_run(%Session{} = session, output, events, %Policy{} = policy) do
    updated_trajectory =
      session.trajectory
      |> Trajectory.append_events!(events)
      |> Trajectory.record!(
        status: output_status(output),
        final_snapshot: output.state || session.snapshot,
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
    |> Session.with_snapshot(output.state || session.snapshot)
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

  defp session_recipe_opts(%Session{} = session, %Policy{} = policy) do
    recipe_opts =
      session.metadata
      |> Map.get(:recipe_opts, [])
      |> Keyword.put(:state, session.snapshot)

    if policy.max_turns do
      Keyword.put_new(recipe_opts, :max_turns, policy.max_turns)
    else
      recipe_opts
    end
  end

  defp effective_policy(%Session{metadata: metadata}, nil) do
    metadata
    |> Map.get(:policy)
    |> Policy.from_input!()
  rescue
    _ -> Policy.new!()
  end

  defp effective_policy(%Session{} = _session, policy_input), do: Policy.from_input!(policy_input)

  defp normalize_turn_input(%RunicAI.ReviewDecision{} = input, %State{} = state),
    do: %{state: state, review_decision: input}

  defp normalize_turn_input(%RunicAI.ReviewDecision{} = input, _snapshot),
    do: %{review_decision: input}

  defp normalize_turn_input(%RunicAI.ResumeSignal{} = input, %State{} = state),
    do: %{state: state, resume_signal: input}

  defp normalize_turn_input(%RunicAI.ResumeSignal{} = input, _snapshot),
    do: %{resume_signal: input}

  defp normalize_turn_input(%RunicAI.Message{} = input, %State{} = state),
    do: %{input_message: input, state: state}

  defp normalize_turn_input(%RunicAI.Message{} = input, _snapshot), do: %{input_message: input}

  defp normalize_turn_input(%{} = input, %State{} = state), do: Map.put_new(input, :state, state)
  defp normalize_turn_input(%{} = input, _snapshot), do: input

  defp normalize_turn_input(input, %State{} = state) when is_binary(input),
    do: %{user: input, state: state}

  defp normalize_turn_input(input, _snapshot) when is_binary(input), do: %{user: input}
  defp normalize_turn_input(input, %State{} = state), do: %{state: state, input: input}
  defp normalize_turn_input(input, _snapshot), do: %{input: input}

  defp invoke_optional(module, function, args) do
    if module_exports?(module, function, length(args)) do
      apply(module, function, args)
    end
  end

  defp latest_struct(%Workflow{} = workflow, module) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%{__struct__: ^module}, &1))
    |> List.last()
  end

  defp latest_tool_results(%Workflow{} = workflow) do
    case latest_struct(workflow, RunicAI.Tool.BatchResult) do
      %RunicAI.Tool.BatchResult{results: results} -> results
      _ -> nil
    end
  end

  defp fallback_state(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%State{}, &1))
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

  defp initial_snapshot(recipe, recipe_opts) do
    cond do
      module_exports?(recipe, :initial_state, 1) ->
        apply(recipe, :initial_state, [recipe_opts])

      match?(%State{}, Keyword.get(recipe_opts, :state)) ->
        Keyword.get(recipe_opts, :state)

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

  defp output_status(%{review_request: %RunicAI.ReviewRequest{}}), do: :review
  defp output_status(%{wait: %RunicAI.Wait{}}), do: :wait
  defp output_status(%{turn_result: %RunicAI.Agent.TurnResult{kind: kind}}), do: kind
  defp output_status(_output), do: :ok

  defp session_status_from_output(%{review_request: %RunicAI.ReviewRequest{}}), do: :review
  defp session_status_from_output(%{wait: %RunicAI.Wait{}}), do: :waiting

  defp session_status_from_output(%{state: %State{status: :completed}}), do: :completed
  defp session_status_from_output(%{state: %State{status: :halted}}), do: :error
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
