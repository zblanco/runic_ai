defmodule RunicAI.Recipes.IntegratedToolAgent do
  @moduledoc """
  Workflow-owned tool agent recipe with scoped budget, guard, wait, and review handling.
  """

  alias Runic.Workflow
  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Coding.TraceRedactor
  alias RunicAI.Control.BudgetDecision
  alias RunicAI.Control.GuardDecision
  alias RunicAI.Control.GuardRequest
  alias RunicAI.Integrated.Emission
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Integrated.Signal
  alias RunicAI.LLM.Result, as: LLMResult
  alias RunicAI.Message
  alias RunicAI.Recipes.ChatAgentKernel
  alias RunicAI.Recipes.IntegratedAgentKernel
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Steps.ApplyIntegratedTurnResult
  alias RunicAI.Steps.ApplyReviewDecision
  alias RunicAI.Steps.AppendToolObservations
  alias RunicAI.Steps.AssembleTurnPrompt
  alias RunicAI.Steps.AttachVisibleTools
  alias RunicAI.Steps.EvaluateBudget
  alias RunicAI.Steps.EvaluateGuard
  alias RunicAI.Steps.ExecuteToolCallsControlled
  alias RunicAI.Steps.GenerateTurnControlled
  alias RunicAI.Steps.InterpretToolRequests
  alias RunicAI.Steps.InterpretTurn
  alias RunicAI.Steps.MaterializeIntegratedTurn
  alias RunicAI.Steps.PlanToolExecution
  alias RunicAI.Steps.ReduceToolResults
  alias RunicAI.Steps.RegisterIntegratedPause
  alias RunicAI.Steps.ResolveIntegratedResume
  alias RunicAI.Steps.SelectTools
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Tool.RequirementPolicy
  alias RunicAI.Tool.Selection
  alias RunicAI.Trace.Event
  alias RunicAI.Wait

  @pre_answer_checkpoints [:pre_answer, :pre_answer_budget]
  @pre_tool_checkpoints [:pre_tool, :pre_tool_budget]
  @verification_tools ~w(compile_project run_tests run_formatter run_linter project_command runtime_smoke source_assert)

  @spec new(keyword()) :: Workflow.t()
  def new(opts \\ []) do
    profiles = build_profiles(opts)
    default_agent_id = default_agent_id(opts, profiles)

    IntegratedAgentKernel.new(
      name: Keyword.get(opts, :name, :integrated_tool_agent),
      default_agent_id: default_agent_id,
      initial_runtime: Keyword.get(opts, :initial_runtime),
      initial_agents: Enum.map(profiles, &build_session/1),
      session_builder: fn agent_id, _signal ->
        agent_id
        |> profile_for_agent(profiles, opts)
        |> build_session()
      end,
      processor: &process_bundle(&1, opts)
    )
  end

  @spec runtime_state(Workflow.t()) :: RunicAI.Integrated.RuntimeState.t() | nil
  def runtime_state(%Workflow{} = workflow), do: IntegratedAgentKernel.runtime_state(workflow)

  @spec initial_runtime(keyword()) :: RunicAI.Integrated.RuntimeState.t()
  def initial_runtime(opts \\ []) do
    profiles = build_profiles(opts)
    default_agent_id = default_agent_id(opts, profiles)

    RunicAI.Integrated.RuntimeState.new!(
      agents: Enum.map(profiles, &build_session/1),
      metadata: %{default_agent_id: default_agent_id}
    )
  end

  @spec session(Workflow.t(), String.t() | atom()) :: SessionState.t() | nil
  def session(%Workflow{} = workflow, agent_id),
    do: IntegratedAgentKernel.session(workflow, agent_id)

  @spec emissions(Workflow.t()) :: [Emission.t()]
  def emissions(%Workflow{} = workflow), do: IntegratedAgentKernel.emissions(workflow)

  @spec latest_turn_result(Workflow.t(), String.t() | atom() | nil) :: TurnResult.t() | nil
  def latest_turn_result(%Workflow{} = workflow, agent_id \\ nil) do
    workflow
    |> emissions()
    |> Enum.reverse()
    |> Enum.find_value(fn emission ->
      if emission.kind in [:reply, :final] and
           (is_nil(agent_id) or emission.agent_id == normalize_agent_id(agent_id)) do
        emission.value
      end
    end)
  end

  @spec latest_reply_text(Workflow.t(), String.t() | atom() | nil) :: String.t() | nil
  def latest_reply_text(%Workflow{} = workflow, agent_id \\ nil) do
    case latest_turn_result(workflow, agent_id) do
      %TurnResult{message: %Message{} = message} -> message.content
      _ -> nil
    end
  end

  @spec latest_review_request(Workflow.t(), String.t() | atom() | nil) :: ReviewRequest.t() | nil
  def latest_review_request(%Workflow{} = workflow, agent_id \\ nil) do
    workflow
    |> emissions()
    |> Enum.reverse()
    |> Enum.find_value(fn emission ->
      if emission.kind == :review and
           (is_nil(agent_id) or emission.agent_id == normalize_agent_id(agent_id)) do
        emission.value
      end
    end)
  end

  @spec latest_wait(Workflow.t(), String.t() | atom() | nil) :: Wait.t() | nil
  def latest_wait(%Workflow{} = workflow, agent_id \\ nil) do
    workflow
    |> emissions()
    |> Enum.reverse()
    |> Enum.find_value(fn emission ->
      if emission.kind == :wait and
           (is_nil(agent_id) or emission.agent_id == normalize_agent_id(agent_id)) do
        emission.value
      end
    end)
  end

  defp process_bundle(%{signal: %Signal{kind: :review_decision}} = bundle, _opts) do
    process_review_decision(bundle)
  end

  defp process_bundle(%{signal: %Signal{kind: kind}} = bundle, _opts)
       when kind in [:resume, :wake] do
    process_wait_resume(bundle)
  end

  defp process_bundle(bundle, _opts) do
    materialized = MaterializeIntegratedTurn.materialize!(bundle)
    session = materialized.session
    lane_opts = lane_options(session)

    selection =
      SelectTools.select!(materialized.turn_request,
        registry: Map.get(lane_opts, :registry, []),
        selector: Map.get(lane_opts, :selector),
        visible_tools: Map.get(lane_opts, :visible_tools),
        metadata: Map.get(lane_opts, :tool_metadata, %{})
      )

    attached_turn_request =
      AttachVisibleTools.attach!(
        materialized.turn_request,
        selection,
        tool_requirement: Map.get(lane_opts, :tool_requirement)
      )

    prompt = AssembleTurnPrompt.build_prompt(attached_turn_request)

    turn_result =
      attached_turn_request
      |> GenerateTurnControlled.generate(
        prompt,
        retry_policy: Map.get(lane_opts, :generation_retry_policy),
        fallback_policy: Map.get(lane_opts, :generation_fallback_policy)
      )
      |> InterpretTurn.interpret!(
        final_pattern: Map.get(lane_opts, :final_pattern),
        final_when: Map.get(lane_opts, :final_when)
      )
      |> InterpretToolRequests.normalize!(selection)

    materialized = %{materialized | turn_request: attached_turn_request}

    case turn_result.kind do
      :tool_requests ->
        process_tool_requests(materialized, selection, turn_result, lane_opts)

      _ ->
        process_answer(materialized, turn_result, lane_opts)
    end
  end

  defp process_review_decision(%{session: %SessionState{} = session, signal: %Signal{} = signal}) do
    pending_work = session.pending_work
    review_request = pending_work.request
    review_decision = ReviewDecision.from_input!(signal.payload)
    {^signal, dequeued_session} = SessionState.dequeue_signal!(session)

    base_session =
      dequeued_session
      |> SessionState.clear_pending_work!(status: :idle)
      |> reset_tool_traces(signal)

    lane_opts = lane_options(base_session)

    case ApplyReviewDecision.apply_decision!(review_request, review_decision) do
      %ContinueDecision{} = continue_decision ->
        terminal_session_update(base_session, base_session.agent_state, continue_decision)

      resolved ->
        case pending_work.checkpoint do
          checkpoint when checkpoint in @pre_answer_checkpoints ->
            turn_request = Map.fetch!(pending_work.metadata, :turn_request)
            original_turn_result = Map.fetch!(pending_work.metadata, :turn_result)

            resolved_turn_result =
              normalize_reviewed_turn_result(resolved, original_turn_result.kind)

            update =
              ApplyIntegratedTurnResult.apply_result!(
                %{
                  agent_id: base_session.agent.id,
                  session: base_session,
                  turn_request: turn_request
                },
                resolved_turn_result,
                continue_opts(lane_opts)
              )

            %{update | session: carry_budget_snapshot(update.session, base_session)}

          checkpoint when checkpoint in @pre_tool_checkpoints ->
            selection = Map.fetch!(pending_work.metadata, :selection)

            execution_plan =
              normalize_resolved_execution_plan(
                resolved,
                Map.fetch!(pending_work.metadata, :execution_plan)
              )
              |> mark_execution_plan_reviewed(review_decision)

            original_turn_result = Map.fetch!(pending_work.metadata, :turn_result)

            execute_planned_tools(
              begin_tool_trace(base_session, execution_plan),
              execution_plan,
              selection,
              original_turn_result,
              lane_opts
            )
        end
    end
  end

  defp process_wait_resume(%{session: %SessionState{} = session} = bundle) do
    pending_work = session.pending_work
    resolved_bundle = ResolveIntegratedResume.resolve!(bundle)
    base_session = reset_tool_traces(resolved_bundle.session, resolved_bundle.signal)
    lane_opts = lane_options(base_session)

    case pending_work.checkpoint do
      checkpoint when checkpoint in @pre_answer_checkpoints ->
        turn_request = Map.fetch!(pending_work.metadata, :turn_request)
        turn_result = Map.fetch!(pending_work.metadata, :turn_result)

        update =
          ApplyIntegratedTurnResult.apply_result!(
            %{
              agent_id: base_session.agent.id,
              session: base_session,
              turn_request: turn_request
            },
            turn_result,
            continue_opts(lane_opts)
          )

        %{update | session: carry_budget_snapshot(update.session, base_session)}

      checkpoint when checkpoint in @pre_tool_checkpoints ->
        selection = Map.fetch!(pending_work.metadata, :selection)
        execution_plan = Map.fetch!(pending_work.metadata, :execution_plan)
        turn_result = Map.fetch!(pending_work.metadata, :turn_result)

        execute_planned_tools(
          begin_tool_trace(base_session, execution_plan),
          execution_plan,
          selection,
          turn_result,
          lane_opts
        )
    end
  end

  defp process_tool_requests(
         materialized,
         %Selection{} = selection,
         %TurnResult{} = turn_result,
         lane_opts
       ) do
    projected_state =
      State.apply_turn_result!(
        materialized.session.agent_state,
        materialized.turn_request,
        turn_result
      )

    base_session =
      materialized.session
      |> SessionState.with_agent_state!(projected_state)
      |> SessionState.clear_pending_work!(status: :running)
      |> merge_turn_metrics(turn_result)

    execution_plan =
      PlanToolExecution.plan!(turn_result, selection,
        execution_policy: Map.get(lane_opts, :execution_policy),
        planner: Map.get(lane_opts, :tool_planner)
      )

    base_session = begin_tool_trace(base_session, execution_plan)

    budget_decision =
      EvaluateBudget.evaluate!(
        %{
          state: projected_state,
          turn_result: turn_result,
          execution_plan: execution_plan,
          runtime: budget_runtime(base_session)
        },
        budget_policy: Map.get(lane_opts, :budget_policy)
      )

    session_after_budget = put_budget_snapshot(base_session, budget_decision)

    case budget_decision.action do
      :continue ->
        :ok

      action when action in [:review, :wait] ->
        pause_request =
          budget_pause_request(
            session_after_budget,
            execution_plan,
            budget_decision,
            :pre_tool_budget
          )

        return_pause(
          session_after_budget,
          pause_request,
          selection: selection,
          execution_plan: execution_plan,
          turn_result: turn_result
        )

      :halt ->
        return_terminal(
          session_after_budget,
          projected_state,
          budget_terminal_decision(budget_decision, :pre_tool_budget)
        )
    end
    |> case do
      :ok ->
        guard_request =
          GuardRequest.new!(
            :pre_tool,
            projected_state,
            turn_result: turn_result,
            execution_plan: execution_plan,
            subject: execution_plan,
            policy: Map.get(lane_opts, :pre_tool_guard_policy),
            metadata: %{guard_point: :pre_tool}
          )

        guard_decision =
          EvaluateGuard.evaluate!(
            guard_request,
            evaluator: Map.get(lane_opts, :pre_tool_guard)
          )

        case resolve_execution_plan_guard(execution_plan, guard_request, guard_decision) do
          {:continue, resolved_execution_plan} ->
            execute_planned_tools(
              session_after_budget,
              resolved_execution_plan,
              selection,
              turn_result,
              lane_opts
            )

          {:pause, pause_request} ->
            return_pause(
              session_after_budget,
              pause_request,
              selection: selection,
              execution_plan: execution_plan,
              turn_result: turn_result
            )

          {:terminal, continue_decision} ->
            return_terminal(session_after_budget, projected_state, continue_decision)
        end

      update ->
        update
    end
  end

  defp process_answer(materialized, %TurnResult{} = turn_result, lane_opts) do
    projected_state =
      State.apply_turn_result!(
        materialized.turn_request.state,
        materialized.turn_request,
        turn_result
      )

    budget_decision =
      EvaluateBudget.evaluate!(
        %{
          state: projected_state,
          turn_result: turn_result,
          runtime: budget_runtime(materialized.session)
        },
        budget_policy: Map.get(lane_opts, :budget_policy)
      )

    session_after_budget = put_budget_snapshot(materialized.session, budget_decision)

    case budget_decision.action do
      :continue ->
        :ok

      action when action in [:review, :wait] ->
        pause_state = answer_pause_state(materialized.turn_request, projected_state)

        pause_request =
          budget_pause_request(
            session_after_budget,
            turn_result,
            budget_decision,
            :pre_answer_budget
          )

        return_pause(
          session_after_budget
          |> SessionState.with_agent_state!(pause_state)
          |> merge_turn_metrics(turn_result),
          pause_request,
          turn_request: materialized.turn_request,
          turn_result: turn_result
        )

      :halt ->
        pause_state = answer_pause_state(materialized.turn_request, projected_state)

        return_terminal(
          session_after_budget |> merge_turn_metrics(turn_result),
          pause_state,
          budget_terminal_decision(budget_decision, :pre_answer_budget)
        )
    end
    |> case do
      :ok ->
        guard_request =
          GuardRequest.new!(
            :pre_answer,
            projected_state,
            turn_result: turn_result,
            subject: turn_result,
            candidate_message: turn_result.message,
            policy: Map.get(lane_opts, :pre_answer_guard_policy),
            metadata: %{guard_point: :pre_answer}
          )

        guard_decision =
          EvaluateGuard.evaluate!(
            guard_request,
            evaluator: Map.get(lane_opts, :pre_answer_guard)
          )

        case resolve_answer_guard(turn_result, guard_request, guard_decision) do
          {:continue, resolved_turn_result} ->
            update =
              ApplyIntegratedTurnResult.apply_result!(
                materialized,
                resolved_turn_result,
                continue_opts(lane_opts)
              )

            %{update | session: carry_budget_snapshot(update.session, session_after_budget)}

          {:pause, pause_request} ->
            pause_state = answer_pause_state(materialized.turn_request, projected_state)

            return_pause(
              session_after_budget
              |> SessionState.with_agent_state!(pause_state)
              |> merge_turn_metrics(turn_result),
              pause_request,
              turn_request: materialized.turn_request,
              turn_result: turn_result
            )

          {:terminal, continue_decision} ->
            pause_state = answer_pause_state(materialized.turn_request, projected_state)

            return_terminal(
              session_after_budget |> merge_turn_metrics(turn_result),
              pause_state,
              continue_decision
            )
        end

      update ->
        update
    end
  end

  defp execute_planned_tools(
         %SessionState{} = session,
         %ExecutionPlan{} = execution_plan,
         %Selection{} = selection,
         %TurnResult{} = turn_result,
         lane_opts
       ) do
    emit_tool_call_events(session, execution_plan, lane_opts)

    raw_batch_result =
      ExecuteToolCallsControlled.execute!(execution_plan, selection,
        retry_policy: Map.get(lane_opts, :tool_retry_policy),
        fallback_policy: Map.get(lane_opts, :tool_fallback_policy)
      )

    batch_result = ReduceToolResults.reduce!(execution_plan, raw_batch_result)
    emit_tool_result_events(session, batch_result, lane_opts)

    state_after_observations =
      AppendToolObservations.append!(
        session.agent_state,
        execution_plan,
        batch_result
      )

    continue_decision =
      RunicAI.Rules.ContinueChat.decide!(
        state_after_observations,
        turn_result,
        continue_opts(lane_opts)
      )

    updated_session =
      session
      |> SessionState.with_agent_state!(state_after_observations)
      |> SessionState.clear_pending_work!(
        status: post_tool_status(state_after_observations, continue_decision)
      )
      |> complete_tool_trace(batch_result)
      |> merge_batch_metrics(batch_result)
      |> put_control(:last_continue_decision, continue_decision)

    cond do
      continue_decision.action == :continue and state_after_observations.status == :running ->
        %{
          session: SessionState.with_status!(updated_session, :idle),
          prepend_signals: [Signal.new!(:continue, agent_id: updated_session.agent.id)],
          emissions: []
        }

      continue_decision.action in [:halt, :stop] or
          state_after_observations.status in [:completed, :halted] ->
        %{
          session: updated_session,
          emissions: [Emission.new!(updated_session.agent.id, :status, value: continue_decision)]
        }

      true ->
        %{session: updated_session, emissions: []}
    end
  end

  defp resolve_execution_plan_guard(
         %ExecutionPlan{} = execution_plan,
         %GuardRequest{} = _guard_request,
         %GuardDecision{action: :allow}
       ) do
    {:continue, execution_plan}
  end

  defp resolve_execution_plan_guard(
         _execution_plan,
         %GuardRequest{} = _guard_request,
         %GuardDecision{action: :rewrite, replacement: %ExecutionPlan{} = replacement}
       ) do
    {:continue, replacement}
  end

  defp resolve_execution_plan_guard(
         _execution_plan,
         %GuardRequest{} = guard_request,
         %GuardDecision{action: action} = guard_decision
       )
       when action in [:review, :wait] do
    {:pause, guard_pause_request(guard_request, guard_decision)}
  end

  defp resolve_execution_plan_guard(
         _execution_plan,
         %GuardRequest{} = guard_request,
         %GuardDecision{action: :deny} = guard_decision
       ) do
    {:terminal, guard_terminal_decision(guard_request, guard_decision)}
  end

  defp resolve_execution_plan_guard(
         _execution_plan,
         %GuardRequest{} = guard_request,
         %GuardDecision{action: :rewrite, replacement: nil}
       ) do
    {:terminal,
     ContinueDecision.halt!(:guard_invalid_rewrite, metadata: %{guard_point: guard_request.point})}
  end

  defp resolve_answer_guard(
         %TurnResult{} = turn_result,
         %GuardRequest{} = _guard_request,
         %GuardDecision{action: :allow}
       ) do
    {:continue, turn_result}
  end

  defp resolve_answer_guard(
         %TurnResult{kind: kind},
         %GuardRequest{} = _guard_request,
         %GuardDecision{action: :rewrite, replacement: replacement}
       )
       when not is_nil(replacement) do
    {:continue, normalize_reviewed_turn_result(replacement, kind)}
  end

  defp resolve_answer_guard(
         _turn_result,
         %GuardRequest{} = guard_request,
         %GuardDecision{action: action} = guard_decision
       )
       when action in [:review, :wait] do
    {:pause, guard_pause_request(guard_request, guard_decision)}
  end

  defp resolve_answer_guard(
         _turn_result,
         %GuardRequest{} = guard_request,
         %GuardDecision{action: :deny} = guard_decision
       ) do
    {:terminal, guard_terminal_decision(guard_request, guard_decision)}
  end

  defp resolve_answer_guard(
         _turn_result,
         %GuardRequest{} = guard_request,
         %GuardDecision{action: :rewrite, replacement: nil}
       ) do
    {:terminal,
     ContinueDecision.halt!(:guard_invalid_rewrite, metadata: %{guard_point: guard_request.point})}
  end

  defp return_pause(%SessionState{} = session, pause_request, metadata) do
    emit_pause_event(session, pause_request, lane_options(session))
    RegisterIntegratedPause.register!(session, pause_request, metadata: Enum.into(metadata, %{}))
  end

  defp return_terminal(
         %SessionState{} = session,
         %State{} = agent_state,
         %ContinueDecision{} = continue_decision
       ) do
    terminal_session_update(session, agent_state, continue_decision)
  end

  defp terminal_session_update(
         %SessionState{} = session,
         %State{} = agent_state,
         %ContinueDecision{} = continue_decision
       ) do
    finalized_state =
      case continue_decision.action do
        :halt -> State.with_status!(agent_state, :halted)
        :stop -> State.with_status!(agent_state, :completed)
        _ -> agent_state
      end

    finalized_session =
      session
      |> SessionState.with_agent_state!(finalized_state)
      |> SessionState.clear_pending_work!(status: session_status_for_decision(continue_decision))
      |> put_control(:last_continue_decision, continue_decision)

    %{
      session: finalized_session,
      emissions: [Emission.new!(session.agent.id, :status, value: continue_decision)]
    }
  end

  defp answer_pause_state(%TurnRequest{} = turn_request, %State{} = projected_state) do
    state_with_user_message =
      case turn_request.input_message do
        %Message{} = input_message ->
          %State{} = State.append_messages!(turn_request.state, [input_message])

        _ ->
          %State{} = turn_request.state
      end

    %State{
      state_with_user_message
      | metadata: projected_state.metadata,
        last_turn_result: projected_state.last_turn_result
    }
  end

  defp budget_pause_request(
         %SessionState{} = session,
         subject,
         %BudgetDecision{action: :review} = budget_decision,
         checkpoint
       ) do
    ReviewRequest.new!(
      :budget_review,
      checkpoint: checkpoint,
      resume_key: pause_resume_key(:review, checkpoint, session),
      subject: subject,
      details: %{budget_decision: budget_decision},
      metadata: %{checkpoint: checkpoint}
    )
  end

  defp budget_pause_request(
         %SessionState{} = session,
         subject,
         %BudgetDecision{} = budget_decision,
         checkpoint
       ) do
    Wait.new!(
      :budget,
      reason: :budget_exhausted,
      resume_key: pause_resume_key(:wait, checkpoint, session),
      until: extract_until(budget_decision),
      payload: %{subject: subject, budget_decision: budget_decision},
      details: %{budget_decision: budget_decision},
      metadata: %{checkpoint: checkpoint}
    )
  end

  defp budget_terminal_decision(%BudgetDecision{} = budget_decision, checkpoint) do
    ContinueDecision.halt!(:budget_exhausted,
      metadata: %{checkpoint: checkpoint, reasons: budget_decision.reasons}
    )
  end

  defp guard_pause_request(
         %GuardRequest{} = guard_request,
         %GuardDecision{action: :review} = guard_decision
       ) do
    ReviewRequest.new!(
      :guard_review,
      checkpoint: guard_request.point,
      resume_key: pause_resume_key(:review, guard_request.point, guard_request.state),
      subject: guard_request.subject,
      details: %{guard_request: guard_request, guard_decision: guard_decision},
      metadata: %{checkpoint: guard_request.point, guard_point: guard_request.point}
    )
  end

  defp guard_pause_request(%GuardRequest{} = guard_request, %GuardDecision{} = guard_decision) do
    Wait.new!(
      :guard,
      reason: guard_decision.reason,
      resume_key: pause_resume_key(:wait, guard_request.point, guard_request.state),
      until: extract_until(guard_decision),
      payload: %{subject: guard_request.subject, guard_request: guard_request},
      details: %{guard_request: guard_request, guard_decision: guard_decision},
      metadata: %{checkpoint: guard_request.point, guard_point: guard_request.point}
    )
  end

  defp guard_terminal_decision(%GuardRequest{} = guard_request, %GuardDecision{} = guard_decision) do
    ContinueDecision.halt!(:guard_denied,
      metadata: %{guard_point: guard_request.point, reason: guard_decision.reason}
    )
  end

  defp carry_budget_snapshot(%SessionState{} = session, %SessionState{} = source_session) do
    case Map.get(source_session.control, :last_budget_snapshot) do
      nil -> session
      snapshot -> put_control(session, :last_budget_snapshot, snapshot)
    end
  end

  defp put_budget_snapshot(%SessionState{} = session, %BudgetDecision{} = budget_decision) do
    put_control(session, :last_budget_snapshot, budget_decision.snapshot)
  end

  defp put_control(%SessionState{} = session, key, value) do
    %SessionState{session | control: Map.put(session.control, key, value)}
  end

  defp merge_turn_metrics(%SessionState{} = session, %TurnResult{raw: %LLMResult{} = llm_result}) do
    usage = normalize_usage(llm_result.usage)
    token_usage = normalize_usage(Map.get(session.control, :token_usage, %{}))

    %SessionState{
      session
      | control:
          session.control
          |> Map.put(:attempts, Map.get(session.control, :attempts, 0) + 1)
          |> Map.put(:model_calls, Map.get(session.control, :model_calls, 0) + 1)
          |> Map.put(:token_usage, merge_usage(token_usage, usage))
    }
  end

  defp merge_turn_metrics(%SessionState{} = session, %TurnResult{} = turn_result) do
    retries =
      if get_in(turn_result.details, [:retryable]) do
        Map.get(session.control, :retries, 0) + 1
      else
        Map.get(session.control, :retries, 0)
      end

    %SessionState{
      session
      | control:
          session.control
          |> Map.put(:attempts, Map.get(session.control, :attempts, 0) + 1)
          |> Map.put(:retries, retries)
    }
  end

  defp merge_batch_metrics(%SessionState{} = session, %BatchResult{results: results}) do
    %SessionState{
      session
      | control:
          session.control
          |> Map.put(:tool_calls, Map.get(session.control, :tool_calls, 0) + length(results))
          |> Map.put(
            :retries,
            Map.get(session.control, :retries, 0) + Enum.count(results, &(&1.status == :retry))
          )
    }
  end

  defp begin_tool_trace(%SessionState{} = session, %ExecutionPlan{} = execution_plan) do
    traces = Map.get(session.control, :last_tool_traces, [])

    %SessionState{
      session
      | control:
          Map.put(
            session.control,
            :last_tool_traces,
            traces ++ [%{execution_plan: execution_plan, batch_result: nil}]
          )
    }
  end

  defp emit_tool_call_events(
         %SessionState{} = session,
         %ExecutionPlan{} = execution_plan,
         lane_opts
       ) do
    Enum.each(execution_plan.calls, fn %CallRequest{} = call ->
      emit_trace_event(
        lane_opts,
        Event.new!(:coding_tool_call,
          agent_id: session.agent.id,
          conversation_id: session.agent.conversation_id,
          status: :running,
          output:
            TraceRedactor.redact(%{
              id: call.id,
              tool: call.tool_name,
              arguments: call.arguments,
              request_index: call.request_index
            }),
          metadata: %{
            coding?: true,
            live?: true,
            source: :integrated_tool_agent,
            tool_name: call.tool_name
          }
        )
      )
    end)
  end

  defp emit_tool_result_events(
         %SessionState{} = session,
         %BatchResult{} = batch_result,
         lane_opts
       ) do
    Enum.each(batch_result.results, fn %CallResult{} = result ->
      emit_trace_event(lane_opts, tool_observation_event(session, result))

      if result.request.tool_name in @verification_tools do
        emit_trace_event(lane_opts, verification_observation_event(session, result))
      end
    end)
  end

  defp tool_observation_event(%SessionState{} = session, %CallResult{} = result) do
    Event.new!(:coding_tool_observation,
      agent_id: session.agent.id,
      conversation_id: session.agent.conversation_id,
      status: result.status,
      output: TraceRedactor.redact(call_result_summary(result)),
      metadata: %{
        coding?: true,
        live?: true,
        source: :integrated_tool_agent,
        tool_name: result.request.tool_name
      }
    )
  end

  defp verification_observation_event(%SessionState{} = session, %CallResult{} = result) do
    Event.new!(:coding_verification_observation,
      agent_id: session.agent.id,
      conversation_id: session.agent.conversation_id,
      status: result.status,
      output: TraceRedactor.redact(call_result_summary(result)),
      metadata: %{
        coding?: true,
        live?: true,
        verification?: true,
        source: :integrated_tool_agent,
        tool_name: result.request.tool_name,
        status: result.status
      }
    )
  end

  defp call_result_summary(%CallResult{} = result) do
    %{
      id: result.request.id,
      tool: result.request.tool_name,
      status: result.status,
      output: result.output,
      error: result.error,
      started_at: result.started_at,
      completed_at: result.completed_at,
      metadata: result.metadata
    }
  end

  defp emit_pause_event(%SessionState{} = session, %ReviewRequest{} = request, lane_opts) do
    emit_trace_event(
      lane_opts,
      Event.new!(:review_requested,
        agent_id: session.agent.id,
        conversation_id: session.agent.conversation_id,
        status: :review,
        output: TraceRedactor.redact(%{details: request.details, subject: request.subject}),
        metadata:
          Map.merge(request.metadata || %{}, %{
            live?: true,
            source: :integrated_tool_agent,
            kind: request.kind,
            checkpoint: request.checkpoint,
            resume_key: request.resume_key
          })
      )
    )
  end

  defp emit_pause_event(%SessionState{} = session, %Wait{} = wait, lane_opts) do
    emit_trace_event(
      lane_opts,
      Event.new!(:wait_registered,
        agent_id: session.agent.id,
        conversation_id: session.agent.conversation_id,
        status: :waiting,
        output: TraceRedactor.redact(%{payload: wait.payload, details: wait.details}),
        metadata:
          Map.merge(wait.metadata || %{}, %{
            live?: true,
            source: :integrated_tool_agent,
            kind: wait.kind,
            resume_key: wait.resume_key
          })
      )
    )
  end

  defp emit_pause_event(_session, _pause_request, _lane_opts), do: :ok

  defp emit_trace_event(lane_opts, %Event{} = event) do
    case Map.get(lane_opts, :event_sink) do
      sink when is_function(sink, 1) ->
        try do
          sink.(event)
        rescue
          _exception -> :ok
        end

      _other ->
        :ok
    end
  end

  defp complete_tool_trace(%SessionState{} = session, %BatchResult{} = batch_result) do
    traces = Map.get(session.control, :last_tool_traces, [])

    updated_traces =
      case Enum.reverse(traces) do
        [%{execution_plan: %ExecutionPlan{}} = trace | rest] ->
          Enum.reverse([%{trace | batch_result: batch_result} | rest])

        _ ->
          traces
      end

    %SessionState{session | control: Map.put(session.control, :last_tool_traces, updated_traces)}
  end

  defp reset_tool_traces(%SessionState{} = session, %Signal{kind: :continue}), do: session

  defp reset_tool_traces(%SessionState{} = session, %Signal{}) do
    %SessionState{session | control: Map.delete(session.control, :last_tool_traces)}
  end

  defp normalize_reviewed_turn_result(%TurnResult{} = turn_result, _kind), do: turn_result

  defp normalize_reviewed_turn_result(%LLMResult{} = result, :final),
    do: TurnResult.final!(result)

  defp normalize_reviewed_turn_result(%LLMResult{} = result, _kind), do: TurnResult.reply!(result)

  defp normalize_reviewed_turn_result(%Message{} = message, :final),
    do: TurnResult.final!(message)

  defp normalize_reviewed_turn_result(%Message{} = message, _kind), do: TurnResult.reply!(message)

  defp normalize_reviewed_turn_result(message, :final) when is_binary(message),
    do: TurnResult.final!(message)

  defp normalize_reviewed_turn_result(message, _kind), do: TurnResult.reply!(message)

  defp normalize_resolved_execution_plan(%ExecutionPlan{} = execution_plan, _original),
    do: execution_plan

  defp normalize_resolved_execution_plan(_resolved, %ExecutionPlan{} = execution_plan),
    do: execution_plan

  defp mark_execution_plan_reviewed(
         %ExecutionPlan{} = execution_plan,
         %ReviewDecision{status: :approved} = decision
       ) do
    metadata = %{
      hitl_approved?: true,
      review_resume_key: decision.resume_key,
      reviewed_at: DateTime.utc_now()
    }

    %{
      execution_plan
      | calls: Enum.map(execution_plan.calls, &mark_call_reviewed(&1, metadata)),
        metadata: Map.merge(execution_plan.metadata, metadata)
    }
  end

  defp mark_execution_plan_reviewed(%ExecutionPlan{} = execution_plan, _decision),
    do: execution_plan

  defp mark_call_reviewed(%CallRequest{} = call, metadata) do
    %{
      call
      | arguments: put_command_arg_metadata(call.tool_name, call.arguments, metadata),
        metadata: Map.merge(call.metadata, metadata)
    }
  end

  defp put_command_arg_metadata(tool_name, arguments, metadata)
       when tool_name in ["run_command", "project_command"] and is_map(arguments) do
    Map.update(arguments, :metadata, metadata, fn existing ->
      existing
      |> normalize_metadata_map()
      |> Map.merge(metadata)
    end)
  end

  defp put_command_arg_metadata(_tool_name, arguments, _metadata), do: arguments

  defp normalize_metadata_map(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata_map(_metadata), do: %{}

  defp budget_runtime(%SessionState{} = session) do
    %{
      recursion_depth: Map.get(session.control, :attempts, 0),
      estimated_cost: Map.get(session.control, :estimated_cost, 0.0)
    }
  end

  defp continue_opts(lane_opts) do
    [
      max_turns: Map.get(lane_opts, :max_turns),
      stop_pattern: Map.get(lane_opts, :stop_pattern),
      continue_when: Map.get(lane_opts, :continue_when)
    ]
  end

  defp post_tool_status(%State{status: :completed}, _continue_decision), do: :completed
  defp post_tool_status(%State{status: :halted}, _continue_decision), do: :halted
  defp post_tool_status(_state, %ContinueDecision{action: :stop}), do: :completed
  defp post_tool_status(_state, %ContinueDecision{action: :halt}), do: :halted
  defp post_tool_status(_state, %ContinueDecision{}), do: :idle

  defp session_status_for_decision(%ContinueDecision{action: :halt}), do: :halted
  defp session_status_for_decision(%ContinueDecision{action: :stop}), do: :completed
  defp session_status_for_decision(%ContinueDecision{}), do: :idle

  defp pause_resume_key(kind, checkpoint, %SessionState{} = session) do
    "integrated:#{kind}:#{checkpoint}:#{session.agent.id}:#{System.unique_integer([:positive])}"
  end

  defp pause_resume_key(kind, checkpoint, %State{} = state) do
    conversation_id = state.metadata[:conversation_id] || "conversation"

    "integrated:#{kind}:#{checkpoint}:#{conversation_id}:#{System.unique_integer([:positive])}"
  end

  defp extract_until(%BudgetDecision{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :until) || Map.get(metadata, "until")
  end

  defp extract_until(%GuardDecision{metadata: metadata, details: details}) do
    Map.get(metadata || %{}, :until) ||
      Map.get(metadata || %{}, "until") ||
      Map.get(details || %{}, :until) ||
      Map.get(details || %{}, "until")
  end

  defp extract_until(_value), do: nil

  defp lane_options(%SessionState{} = session), do: Map.get(session.metadata, :lane_options, %{})

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0,
      output_tokens: Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0,
      total_tokens: Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
    }
  end

  defp normalize_usage(_usage) do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  defp merge_usage(left, right) do
    %{
      input_tokens: Map.get(left, :input_tokens, 0) + Map.get(right, :input_tokens, 0),
      output_tokens: Map.get(left, :output_tokens, 0) + Map.get(right, :output_tokens, 0),
      total_tokens: Map.get(left, :total_tokens, 0) + Map.get(right, :total_tokens, 0)
    }
  end

  defp build_profiles(opts) do
    case Keyword.get(opts, :agents) do
      nil ->
        [default_profile(opts)]

      [] ->
        [default_profile(opts)]

      agents when is_list(agents) ->
        Enum.map(agents, &build_profile(&1, opts))
    end
  end

  defp default_agent_id(opts, [profile | _rest]) do
    profile[:id] ||
      Keyword.get(opts, :default_agent_id) ||
      "agent"
  end

  defp default_agent_id(opts, _profiles) do
    Keyword.get(opts, :default_agent_id, "agent")
  end

  defp profile_for_agent(agent_id, profiles, opts) do
    Enum.find(profiles, fn profile -> profile[:id] == agent_id end) ||
      build_profile([id: agent_id], opts)
  end

  defp build_profile(profile_opts, default_opts) do
    profile =
      default_profile(default_opts)
      |> Keyword.merge(profile_opts)
      |> Keyword.put(
        :id,
        normalize_agent_id(
          Keyword.get(profile_opts, :id) || Keyword.get(default_opts, :default_agent_id, "agent")
        )
      )

    Keyword.put(profile, :tool_requirement, RequirementPolicy.from_recipe_opts!(profile))
  end

  defp default_profile(opts) do
    [
      id: normalize_agent_id(Keyword.get(opts, :default_agent_id, "agent")),
      role: Keyword.get(opts, :role),
      conversation_id: Keyword.get(opts, :conversation_id),
      system: Keyword.get(opts, :system),
      messages: Keyword.get(opts, :messages),
      assigns: Keyword.get(opts, :assigns, %{}),
      state_metadata: Keyword.get(opts, :state_metadata, %{}),
      history_window: Keyword.get(opts, :history_window, :all),
      pinned_messages: Keyword.get(opts, :pinned_messages, []),
      observations: Keyword.get(opts, :observations, []),
      model: Keyword.fetch!(opts, :model),
      llm_opts: recipe_llm_opts(opts),
      metadata: Keyword.get(opts, :metadata, %{}),
      registry: Keyword.get(opts, :registry, []),
      selector: Keyword.get(opts, :tool_selector) || Keyword.get(opts, :selector),
      visible_tools: Keyword.get(opts, :visible_tools),
      tool_requirement: RequirementPolicy.from_recipe_opts!(opts),
      tool_metadata: Keyword.get(opts, :tool_metadata, %{}),
      execution_policy: Keyword.get(opts, :execution_policy),
      tool_planner: Keyword.get(opts, :tool_planner),
      budget_policy: Keyword.get(opts, :budget_policy),
      generation_retry_policy: Keyword.get(opts, :generation_retry_policy),
      generation_fallback_policy: Keyword.get(opts, :generation_fallback_policy),
      tool_retry_policy: Keyword.get(opts, :tool_retry_policy),
      tool_fallback_policy: Keyword.get(opts, :tool_fallback_policy),
      event_sink: Keyword.get(opts, :event_sink),
      pre_tool_guard: Keyword.get(opts, :pre_tool_guard),
      pre_answer_guard: Keyword.get(opts, :pre_answer_guard),
      pre_tool_guard_policy: Keyword.get(opts, :pre_tool_guard_policy),
      pre_answer_guard_policy: Keyword.get(opts, :pre_answer_guard_policy),
      max_turns: Keyword.get(opts, :max_turns),
      stop_pattern: Keyword.get(opts, :stop_pattern),
      continue_when: Keyword.get(opts, :continue_when),
      final_pattern: Keyword.get(opts, :final_pattern),
      final_when: Keyword.get(opts, :final_when)
    ]
  end

  defp build_session(profile) do
    state =
      ChatAgentKernel.initial_state(
        system: profile[:system],
        messages: profile[:messages],
        assigns: profile[:assigns],
        metadata: profile[:state_metadata]
      )

    SessionState.new!(
      profile[:id],
      role: profile[:role],
      conversation_id: profile[:conversation_id],
      agent_state: state,
      metadata: %{
        turn_defaults: %{
          history_window: profile[:history_window],
          pinned_messages: profile[:pinned_messages],
          observations: profile[:observations],
          model: profile[:model],
          llm_opts: profile[:llm_opts],
          metadata: profile[:metadata]
        },
        lane_options: %{
          registry: profile[:registry],
          selector: profile[:selector],
          visible_tools: profile[:visible_tools],
          tool_requirement: profile[:tool_requirement],
          tool_metadata: profile[:tool_metadata],
          execution_policy: profile[:execution_policy],
          tool_planner: profile[:tool_planner],
          budget_policy: profile[:budget_policy],
          generation_retry_policy: profile[:generation_retry_policy],
          generation_fallback_policy: profile[:generation_fallback_policy],
          tool_retry_policy: profile[:tool_retry_policy],
          tool_fallback_policy: profile[:tool_fallback_policy],
          event_sink: profile[:event_sink],
          pre_tool_guard: profile[:pre_tool_guard],
          pre_answer_guard: profile[:pre_answer_guard],
          pre_tool_guard_policy: profile[:pre_tool_guard_policy],
          pre_answer_guard_policy: profile[:pre_answer_guard_policy],
          max_turns: profile[:max_turns],
          stop_pattern: profile[:stop_pattern],
          continue_when: profile[:continue_when],
          final_pattern: profile[:final_pattern],
          final_when: profile[:final_when]
        }
      }
    )
  end

  defp recipe_llm_opts(opts) do
    llm_opts = Keyword.get(opts, :llm_opts, [])

    case Keyword.fetch(opts, :client) do
      {:ok, client} -> Keyword.put(llm_opts, :client, client)
      :error -> llm_opts
    end
  end

  defp normalize_agent_id(agent_id) when is_atom(agent_id), do: Atom.to_string(agent_id)
  defp normalize_agent_id(agent_id), do: agent_id
end
