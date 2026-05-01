defmodule RunicAI.Recipes.GuardedOperatorToolAgent do
  @moduledoc """
  Reference conversational tool agent workflow with budgets, guards, and
  operator-facing pause points.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Control.GuardDecision
  alias RunicAI.Control.GuardRequest
  alias RunicAI.Message
  alias RunicAI.Recipes.ChatAgentKernel
  alias RunicAI.ResumeSignal
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Rules.ContinueChat
  alias RunicAI.Steps.ApplyReviewDecision
  alias RunicAI.Steps.AppendToolObservations
  alias RunicAI.Steps.AssembleTurnPrompt
  alias RunicAI.Steps.AssembleTurnRequest
  alias RunicAI.Steps.AttachVisibleTools
  alias RunicAI.Steps.EvaluateBudget
  alias RunicAI.Steps.EvaluateGuard
  alias RunicAI.Steps.ExecuteToolCallsControlled
  alias RunicAI.Steps.GenerateTurnControlled
  alias RunicAI.Steps.InterpretToolRequests
  alias RunicAI.Steps.InterpretTurn
  alias RunicAI.Steps.NormalizeResumeSignal
  alias RunicAI.Steps.PlanToolExecution
  alias RunicAI.Steps.SelectTools
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Tool.Observation
  alias RunicAI.Tool.RequirementPolicy
  alias RunicAI.Tool.Registry
  alias RunicAI.Tool.Selection
  alias RunicAI.Wait

  @spec new(keyword()) :: Workflow.t()
  def new(opts \\ []) do
    tool_requirement = RequirementPolicy.from_recipe_opts!(opts)

    request_step =
      AssembleTurnRequest.new(
        name: :assemble_turn_request,
        state: Keyword.get(opts, :state),
        system: Keyword.get(opts, :system),
        messages: Keyword.get(opts, :messages),
        assigns: Keyword.get(opts, :assigns, %{}),
        state_metadata: Keyword.get(opts, :state_metadata, %{}),
        history_window: Keyword.get(opts, :history_window, :all),
        pinned_messages: Keyword.get(opts, :pinned_messages, []),
        observations: Keyword.get(opts, :observations, []),
        model: Keyword.fetch!(opts, :model),
        llm_opts: recipe_llm_opts(opts),
        metadata: Keyword.get(opts, :metadata, %{})
      )

    runtime_step =
      Runic.step(
        fn input ->
          Map.get(input, :runtime, %{})
        end,
        name: :control_runtime
      )

    selection_step =
      SelectTools.new(
        name: :select_tools,
        registry: Keyword.get(opts, :registry, []),
        selector: Keyword.get(opts, :tool_selector) || Keyword.get(opts, :selector),
        visible_tools: Keyword.get(opts, :visible_tools),
        metadata: Keyword.get(opts, :tool_metadata, %{})
      )

    attach_tools_step =
      AttachVisibleTools.new(
        name: :attach_visible_tools,
        tool_requirement: tool_requirement
      )

    prompt_step = AssembleTurnPrompt.new(name: :assemble_turn_prompt)

    generate_step =
      GenerateTurnControlled.new(
        name: :generate_turn_controlled,
        retry_policy: Keyword.get(opts, :generation_retry_policy),
        fallback_policy: Keyword.get(opts, :generation_fallback_policy)
      )

    interpret_step =
      InterpretTurn.new(
        name: :interpret_turn,
        final_pattern: Keyword.get(opts, :final_pattern),
        final_when: Keyword.get(opts, :final_when)
      )

    interpret_tool_requests_step = InterpretToolRequests.new(name: :interpret_tool_requests)

    turn_lane_bundle_step =
      Runic.step(
        fn turn_request, selection, turn_result, runtime ->
          %{
            turn_request: turn_request,
            selection: selection,
            turn_result: turn_result,
            runtime: runtime
          }
        end,
        name: :turn_lane_bundle
      )

    tool_lane_rule =
      Runic.rule(
        name: :route_tool_lane,
        condition: fn %{turn_result: %TurnResult{kind: :tool_requests}} -> true end,
        reaction: & &1
      )

    answer_lane_rule =
      Runic.rule(
        name: :route_answer_lane,
        condition: fn %{turn_result: %TurnResult{kind: kind}} -> kind != :tool_requests end,
        reaction: & &1
      )

    prepare_tool_lane_step = prepare_tool_lane_step(opts)
    tool_execution_plan_step = project_field_step(:tool_execution_plan, :execution_plan)
    tool_budget_step = tool_budget_step(opts)
    tool_budget_pause_state_step = tool_budget_pause_state_step()
    tool_budget_terminal_state_step = tool_budget_terminal_state_step()
    pre_tool_guard_step = pre_tool_guard_step(opts)
    pre_tool_guard_pause_state_step = pre_tool_guard_pause_state_step()
    pre_tool_guard_terminal_state_step = pre_tool_guard_terminal_state_step()
    execute_tool_lane_step = execute_tool_lane_step(opts)
    tool_batch_result_step = project_field_step(:tool_batch_result, :batch_result)
    append_tool_lane_step = append_tool_lane_step()
    tool_state_step = project_field_step(:tool_state, :state)
    tool_continue_step = continue_step(:tool_continue_decision, continue_opts(opts))

    prepare_answer_lane_step = prepare_answer_lane_step()
    answer_budget_step = answer_budget_step(opts)
    answer_budget_pause_state_step = answer_budget_pause_state_step()
    answer_budget_terminal_state_step = answer_budget_terminal_state_step()
    pre_answer_guard_step = pre_answer_guard_step(opts)
    pre_answer_guard_pause_state_step = pre_answer_guard_pause_state_step()
    pre_answer_guard_terminal_state_step = pre_answer_guard_terminal_state_step()
    update_answer_lane_step = update_answer_lane_step()
    answer_state_step = project_field_step(:answer_state, :state)
    answer_turn_result_step = project_field_step(:answer_turn_result, :turn_result)
    answer_continue_step = continue_step(:answer_continue_decision, continue_opts(opts))

    Workflow.new(name: Keyword.get(opts, :name, :guarded_operator_tool_agent))
    |> Workflow.add(request_step)
    |> Workflow.add(runtime_step)
    |> Workflow.add(selection_step, to: :assemble_turn_request)
    |> Workflow.add(prompt_step, to: :assemble_turn_request)
    |> Workflow.add(attach_tools_step, to: [:assemble_turn_request, :select_tools])
    |> Workflow.add(generate_step, to: [:attach_visible_tools, :assemble_turn_prompt])
    |> Workflow.add(interpret_step, to: :generate_turn_controlled)
    |> Workflow.add(interpret_tool_requests_step, to: [:interpret_turn, :select_tools])
    |> Workflow.add(turn_lane_bundle_step,
      to: [:assemble_turn_request, :select_tools, :interpret_tool_requests, :control_runtime]
    )
    |> Workflow.add(tool_lane_rule, to: :turn_lane_bundle)
    |> Workflow.add(answer_lane_rule, to: :turn_lane_bundle)
    |> Workflow.add(prepare_tool_lane_step, to: :route_tool_lane)
    |> Workflow.add(tool_execution_plan_step, to: :prepare_tool_lane)
    |> Workflow.add(tool_budget_step, to: :prepare_tool_lane)
    |> add_rules(tool_budget_rules(), :tool_budget)
    |> Workflow.add(tool_budget_pause_state_step, to: :tool_budget)
    |> Workflow.add(tool_budget_terminal_state_step, to: :tool_budget)
    |> Workflow.add(pre_tool_guard_step, to: :tool_budget_continue)
    |> add_rules(pre_tool_guard_rules(), :pre_tool_guard)
    |> Workflow.add(pre_tool_guard_pause_state_step, to: :pre_tool_guard)
    |> Workflow.add(pre_tool_guard_terminal_state_step, to: :pre_tool_guard)
    |> Workflow.add(execute_tool_lane_step, to: :pre_tool_guard_continue)
    |> Workflow.add(tool_batch_result_step, to: :execute_tool_lane)
    |> Workflow.add(append_tool_lane_step, to: :execute_tool_lane)
    |> Workflow.add(tool_state_step, to: :append_tool_lane)
    |> Workflow.add(tool_continue_step, to: [:tool_state, :interpret_tool_requests])
    |> Workflow.add(prepare_answer_lane_step, to: :route_answer_lane)
    |> Workflow.add(answer_budget_step, to: :prepare_answer_lane)
    |> add_rules(answer_budget_rules(), :answer_budget)
    |> Workflow.add(answer_budget_pause_state_step, to: :answer_budget)
    |> Workflow.add(answer_budget_terminal_state_step, to: :answer_budget)
    |> Workflow.add(pre_answer_guard_step, to: :answer_budget_continue)
    |> add_rules(pre_answer_guard_rules(), :pre_answer_guard)
    |> Workflow.add(pre_answer_guard_pause_state_step, to: :pre_answer_guard)
    |> Workflow.add(pre_answer_guard_terminal_state_step, to: :pre_answer_guard)
    |> Workflow.add(update_answer_lane_step, to: :pre_answer_guard_continue)
    |> Workflow.add(answer_state_step, to: :update_answer_lane)
    |> Workflow.add(answer_turn_result_step, to: :update_answer_lane)
    |> Workflow.add(answer_continue_step, to: [:answer_state, :answer_turn_result])
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []), do: ChatAgentKernel.initial_state(opts)

  @spec latest_state(Workflow.t()) :: State.t() | nil
  def latest_state(%Workflow{} = workflow) do
    latest_from_components(workflow, [:answer_state, :tool_state], State) ||
      workflow
      |> Workflow.raw_productions()
      |> Enum.filter(&match?(%State{}, &1))
      |> List.last()
  end

  @spec latest_turn_result(Workflow.t()) :: TurnResult.t() | nil
  def latest_turn_result(%Workflow{} = workflow) do
    latest_from_components(
      workflow,
      [:answer_turn_result, :interpret_tool_requests, :interpret_turn],
      TurnResult
    ) ||
      workflow
      |> Workflow.raw_productions()
      |> Enum.filter(&match?(%TurnResult{}, &1))
      |> List.last()
  end

  @spec latest_continue_decision(Workflow.t()) :: ContinueDecision.t() | nil
  def latest_continue_decision(%Workflow{} = workflow) do
    direct =
      workflow
      |> Workflow.raw_productions()
      |> Enum.filter(&match?(%ContinueDecision{}, &1))
      |> List.last()

    direct ||
      case latest_state(workflow) do
        %State{metadata: metadata} when is_map(metadata) ->
          Map.get(metadata, :last_control_decision)

        _ ->
          nil
      end
  end

  @spec latest_selection(Workflow.t()) :: Selection.t() | nil
  def latest_selection(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%Selection{}, &1))
    |> List.last()
  end

  @spec latest_execution_plan(Workflow.t()) :: ExecutionPlan.t() | nil
  def latest_execution_plan(%Workflow{} = workflow) do
    latest_from_components(workflow, [:tool_execution_plan], ExecutionPlan) ||
      workflow
      |> Workflow.raw_productions()
      |> Enum.filter(&match?(%ExecutionPlan{}, &1))
      |> List.last()
  end

  @spec latest_tool_results(Workflow.t()) :: [CallResult.t()] | nil
  def latest_tool_results(%Workflow{} = workflow) do
    case latest_from_components(workflow, [:tool_batch_result], BatchResult) ||
           latest_struct(workflow, BatchResult) do
      %BatchResult{results: results} -> results
      _ -> nil
    end
  end

  @spec latest_observations(Workflow.t()) :: [Observation.t()] | nil
  def latest_observations(%Workflow{} = workflow) do
    case latest_tool_results(workflow) do
      [_ | _] = results -> Enum.map(results, &Observation.from_call_result!/1)
      _ -> latest_list_of(workflow, Observation)
    end
  end

  @spec latest_review_request(Workflow.t()) :: ReviewRequest.t() | nil
  def latest_review_request(%Workflow{} = workflow) do
    latest_struct(workflow, ReviewRequest) ||
      case latest_state(workflow) do
        %State{pending_action: %ReviewRequest{} = review_request} -> review_request
        _ -> nil
      end
  end

  @spec latest_wait(Workflow.t()) :: Wait.t() | nil
  def latest_wait(%Workflow{} = workflow) do
    latest_struct(workflow, Wait) ||
      case latest_state(workflow) do
        %State{pending_action: %Wait{} = wait} -> wait
        _ -> nil
      end
  end

  @spec latest_reply_text(Workflow.t()) :: String.t() | nil
  def latest_reply_text(%Workflow{} = workflow) do
    case latest_turn_result(workflow) do
      %TurnResult{message: %Message{} = message} -> message.content
      _ -> nil
    end
  end

  @spec react_until_resolution(keyword(), map(), keyword()) :: Workflow.t()
  def react_until_resolution(opts, input, react_opts \\ [])
      when is_list(opts) and is_map(input) do
    do_react_until_resolution(input, opts, react_opts, 0)
  end

  defp do_react_until_resolution(input, opts, react_opts, depth) do
    runtime =
      input
      |> Map.get(:runtime, %{})
      |> Map.put(:recursion_depth, depth)

    workflow =
      run_workflow_for_input(opts, Map.put(input, :runtime, runtime), react_opts)

    max_tool_rounds = Keyword.get(opts, :max_tool_rounds, 8)

    case {
      latest_state(workflow),
      latest_turn_result(workflow),
      latest_continue_decision(workflow),
      latest_review_request(workflow),
      latest_wait(workflow)
    } do
      {%State{status: :running, pending_action: nil} = state, %TurnResult{kind: :tool_requests},
       %ContinueDecision{action: :continue}, nil, nil}
      when depth + 1 < max_tool_rounds ->
        do_react_until_resolution(%{state: state, runtime: runtime}, opts, react_opts, depth + 1)

      _ ->
        workflow
    end
  end

  defp run_workflow_for_input(opts, input, react_opts) do
    case resume_mode(input) do
      :new ->
        new(opts)
        |> Workflow.react_until_satisfied(input, react_opts)

      :resume ->
        resume_workflow(opts)
        |> Workflow.react_until_satisfied(input, react_opts)

      :paused ->
        raise ArgumentError,
              "guarded operator agent state has a pending action; provide review_decision or resume_signal to resume"
    end
  end

  defp resume_mode(%{state: %State{pending_action: %ReviewRequest{}}, review_decision: _}),
    do: :resume

  defp resume_mode(%{state: %State{pending_action: %Wait{}}, resume_signal: _}), do: :resume

  defp resume_mode(%{state: %State{pending_action: pending_action}})
       when not is_nil(pending_action),
       do: :paused

  defp resume_mode(_input), do: :new

  defp resume_workflow(opts) do
    resume_bundle_step =
      Runic.step(
        fn input ->
          resume_bundle!(input, opts)
        end,
        name: :resume_bundle
      )

    Workflow.new(name: :guarded_operator_tool_agent_resume)
    |> Workflow.add(resume_bundle_step)
    |> Workflow.add(project_field_step(:resume_state, :state), to: :resume_bundle)
    |> Workflow.add(project_field_step(:resume_turn_result, :turn_result), to: :resume_bundle)
    |> Workflow.add(project_field_step(:resume_execution_plan, :execution_plan),
      to: :resume_bundle
    )
    |> Workflow.add(project_field_step(:resume_batch_result, :batch_result), to: :resume_bundle)
    |> Workflow.add(project_field_step(:resume_continue_decision, :continue_decision),
      to: :resume_bundle
    )
    |> Workflow.add(project_field_step(:resume_review_request, :review_request),
      to: :resume_bundle
    )
    |> Workflow.add(project_field_step(:resume_wait, :wait), to: :resume_bundle)
  end

  defp resume_bundle!(input, opts) do
    state = resume_state!(input)
    pending_action = pending_action!(state)
    resolved_value = resolve_pending_action!(pending_action, input)

    case resolved_value do
      %ContinueDecision{} = continue_decision ->
        resume_terminal_bundle(state, continue_decision)

      resolved_subject ->
        case resume_checkpoint(pending_action) do
          checkpoint when checkpoint in [:pre_tool, :pre_tool_budget] ->
            resume_tool_bundle(state, resolved_subject, opts)

          checkpoint when checkpoint in [:pre_answer, :pre_answer_budget] ->
            resume_answer_bundle(state, resolved_subject, opts)

          checkpoint ->
            raise ArgumentError, "unsupported pending action checkpoint: #{inspect(checkpoint)}"
        end
    end
  end

  defp resume_state!(%{state: %State{} = state}) do
    case State.validate(state) do
      {:ok, normalized_state} -> normalized_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp resume_state!(input) do
    raise ArgumentError, "resume input must include an Agent.State, got: #{inspect(input)}"
  end

  defp pending_action!(%State{pending_action: %ReviewRequest{} = pending_action}),
    do: pending_action

  defp pending_action!(%State{pending_action: %Wait{} = pending_action}), do: pending_action

  defp pending_action!(%State{} = state) do
    raise ArgumentError,
          "resume requires state.pending_action to be a ReviewRequest or Wait, got: #{inspect(state.pending_action)}"
  end

  defp resolve_pending_action!(%ReviewRequest{} = review_request, input) do
    review_decision =
      input
      |> Map.fetch!(:review_decision)
      |> ReviewDecision.from_input!()

    ApplyReviewDecision.apply_decision!(review_request, review_decision)
  end

  defp resolve_pending_action!(%Wait{} = wait, input) do
    resume_signal =
      input
      |> Map.fetch!(:resume_signal)
      |> ResumeSignal.from_input!()

    wait
    |> NormalizeResumeSignal.normalize!(resume_signal)
    |> resolve_wait_payload(wait)
  end

  defp resolve_wait_payload(nil, %Wait{} = wait), do: wait_original_subject(wait)
  defp resolve_wait_payload(%ContinueDecision{} = continue_decision, _wait), do: continue_decision

  defp resolve_wait_payload(%{decision: decision}, _wait) do
    normalize_continue_decision!(decision)
  end

  defp resolve_wait_payload(%{action: action} = payload, _wait)
       when action in [:continue, :stop, :halt] do
    ContinueDecision.new!(action, Map.get(payload, :reason, action),
      metadata: Map.get(payload, :metadata, %{})
    )
  end

  defp resolve_wait_payload(%{subject: subject}, _wait), do: subject
  defp resolve_wait_payload(%{replacement: replacement}, _wait), do: replacement

  defp resolve_wait_payload(payload, %Wait{} = wait) when is_map(payload),
    do: wait_original_subject(wait)

  defp resolve_wait_payload(payload, _wait), do: payload

  defp normalize_continue_decision!(%ContinueDecision{} = continue_decision) do
    case ContinueDecision.validate(continue_decision) do
      {:ok, normalized_decision} -> normalized_decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_continue_decision!(value) do
    case ContinueDecision.from_value(value, []) do
      {:ok, continue_decision} -> continue_decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp wait_original_subject(%Wait{payload: %{subject: subject}}), do: subject

  defp wait_original_subject(%Wait{details: %{guard_request: %GuardRequest{subject: subject}}}),
    do: subject

  defp wait_original_subject(%Wait{payload: payload}), do: payload

  defp resume_checkpoint(%ReviewRequest{checkpoint: checkpoint}), do: checkpoint

  defp resume_checkpoint(%Wait{metadata: metadata}) do
    Map.get(metadata, :checkpoint) || Map.get(metadata, :guard_point)
  end

  defp resume_terminal_bundle(%State{} = state, %ContinueDecision{} = continue_decision) do
    updated_state =
      state
      |> State.clear_pending_action!()
      |> record_last_control_decision(continue_decision)
      |> apply_terminal_decision(continue_decision)

    %{
      state: updated_state,
      turn_result: nil,
      execution_plan: nil,
      batch_result: nil,
      continue_decision: continue_decision,
      review_request: nil,
      wait: nil
    }
  end

  defp resume_tool_bundle(%State{} = state, resolved_subject, opts) do
    execution_plan = normalize_execution_plan_subject!(resolved_subject)
    selection = resume_selection!(execution_plan, opts)
    turn_result = resume_tool_turn_result!(state)
    cleared_state = State.clear_pending_action!(state)

    batch_result =
      ExecuteToolCallsControlled.execute!(
        execution_plan,
        selection,
        retry_policy: Keyword.get(opts, :tool_retry_policy),
        fallback_policy: Keyword.get(opts, :tool_fallback_policy)
      )

    updated_state = AppendToolObservations.append!(cleared_state, execution_plan, batch_result)
    continue_decision = ContinueChat.decide!(updated_state, turn_result, continue_opts(opts))

    %{
      state: updated_state,
      turn_result: turn_result,
      execution_plan: execution_plan,
      batch_result: batch_result,
      continue_decision: continue_decision,
      review_request: nil,
      wait: nil
    }
  end

  defp resume_answer_bundle(%State{} = state, resolved_subject, opts) do
    turn_result = normalize_answer_subject!(resolved_subject)
    updated_state = commit_resolved_answer!(State.clear_pending_action!(state), turn_result)
    continue_decision = ContinueChat.decide!(updated_state, turn_result, continue_opts(opts))

    %{
      state: updated_state,
      turn_result: turn_result,
      execution_plan: nil,
      batch_result: nil,
      continue_decision: continue_decision,
      review_request: nil,
      wait: nil
    }
  end

  defp resume_selection!(%ExecutionPlan{calls: calls}, opts) do
    registry = Registry.from_input!(Keyword.get(opts, :registry))
    visible_tools = calls |> Enum.map(& &1.tool_name) |> Enum.uniq()
    Selection.new!(registry, visible_tools, metadata: Keyword.get(opts, :tool_metadata, %{}))
  end

  defp resume_tool_turn_result!(%State{
         last_turn_result: %TurnResult{kind: :tool_requests} = turn_result
       }) do
    case TurnResult.validate(turn_result) do
      {:ok, normalized_turn_result} -> normalized_turn_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp resume_tool_turn_result!(%State{} = state) do
    raise ArgumentError,
          "pre-tool resume requires state.last_turn_result to be :tool_requests, got: #{inspect(state.last_turn_result)}"
  end

  defp normalize_execution_plan_subject!(%ExecutionPlan{} = execution_plan) do
    case ExecutionPlan.validate(execution_plan) do
      {:ok, normalized_execution_plan} -> normalized_execution_plan
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_execution_plan_subject!(calls) when is_list(calls) do
    ExecutionPlan.new!(calls)
  end

  defp normalize_execution_plan_subject!(other) do
    raise ArgumentError,
          "pre-tool resume requires an ExecutionPlan or call list, got: #{inspect(other)}"
  end

  defp normalize_answer_subject!(%TurnResult{} = turn_result) do
    case TurnResult.validate(turn_result) do
      {:ok, normalized_turn_result} -> normalized_turn_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_answer_subject!(%Message{} = message), do: TurnResult.reply!(message)
  defp normalize_answer_subject!(text) when is_binary(text), do: TurnResult.reply!(text)

  defp normalize_answer_subject!(other) do
    raise ArgumentError,
          "pre-answer resume requires a TurnResult, assistant message, or string, got: #{inspect(other)}"
  end

  defp commit_resolved_answer!(%State{} = state, %TurnResult{} = turn_result) do
    updated_state =
      case turn_result.message do
        %Message{} = message -> State.append_messages!(state, [message])
        nil -> state
      end

    updated_state =
      updated_state
      |> State.with_last_turn_result!(turn_result)
      |> maybe_apply_turn_result_status(turn_result)

    State.clear_pending_action!(updated_state)
  end

  defp maybe_apply_turn_result_status(%State{} = state, %TurnResult{kind: :final}),
    do: State.with_status!(state, :completed)

  defp maybe_apply_turn_result_status(%State{} = state, %TurnResult{kind: :error}),
    do: State.with_status!(state, :halted)

  defp maybe_apply_turn_result_status(%State{} = state, %TurnResult{}), do: state

  defp latest_list_of(%Workflow{} = workflow, module) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(fn
      [] -> false
      list when is_list(list) -> Enum.all?(list, &match?(%{__struct__: ^module}, &1))
      _ -> false
    end)
    |> List.last()
  end

  defp latest_struct(%Workflow{} = workflow, module) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%{__struct__: ^module}, &1))
    |> List.last()
  end

  defp latest_from_components(
         %Workflow{components: components} = workflow,
         component_names,
         module
       )
       when is_list(component_names) do
    Enum.find_value(component_names, fn component_name ->
      if Map.has_key?(components, component_name) do
        workflow
        |> Workflow.raw_productions(component_name)
        |> Enum.filter(&match?(%{__struct__: ^module}, &1))
        |> List.last()
      end
    end)
  end

  defp recipe_llm_opts(opts) do
    llm_opts = Keyword.get(opts, :llm_opts, [])

    case Keyword.fetch(opts, :client) do
      {:ok, client} -> Keyword.put(llm_opts, :client, client)
      :error -> llm_opts
    end
  end

  defp continue_opts(opts) do
    [
      max_turns: Keyword.get(opts, :max_turns),
      stop_pattern: Keyword.get(opts, :stop_pattern),
      continue_when: Keyword.get(opts, :continue_when)
    ]
  end

  defp add_rules(workflow, rules, parent_name) do
    Enum.reduce(rules, workflow, fn rule, wrk ->
      Workflow.add(wrk, rule, to: parent_name)
    end)
  end

  defp prepare_tool_lane_step(opts) do
    Runic.step(
      fn %{
           turn_request: turn_request,
           turn_result: turn_result,
           selection: selection,
           runtime: _runtime
         } =
           bundle ->
        state = State.apply_turn_result!(turn_request.state, turn_request, turn_result)

        execution_plan =
          PlanToolExecution.plan!(
            turn_result,
            selection,
            execution_policy: Keyword.get(opts, :execution_policy),
            planner: Keyword.get(opts, :tool_planner)
          )

        Map.merge(bundle, %{state: state, execution_plan: execution_plan})
      end,
      name: :prepare_tool_lane
    )
  end

  defp tool_budget_step(opts) do
    Runic.step(
      fn %{
           state: state,
           turn_result: turn_result,
           execution_plan: execution_plan,
           runtime: runtime
         } =
           bundle ->
        decision =
          EvaluateBudget.evaluate!(
            %{
              state: state,
              turn_result: turn_result,
              execution_plan: execution_plan,
              runtime: runtime
            },
            budget_policy: Keyword.get(opts, :budget_policy)
          )

        bundle
        |> Map.put(:subject, execution_plan)
        |> Map.put(:budget_decision, decision)
      end,
      name: :tool_budget
    )
  end

  defp tool_budget_rules do
    [
      Runic.rule(
        name: :tool_budget_continue,
        condition: fn %{budget_decision: %{action: :continue}} -> true end,
        reaction: & &1
      ),
      Runic.rule(
        name: :tool_budget_review,
        condition: fn %{budget_decision: %{action: :review}} -> true end,
        reaction: fn bundle -> budget_pause_action(bundle, :pre_tool_budget) end
      ),
      Runic.rule(
        name: :tool_budget_wait,
        condition: fn %{budget_decision: %{action: :wait}} -> true end,
        reaction: fn bundle -> budget_pause_action(bundle, :pre_tool_budget) end
      ),
      Runic.rule(
        name: :tool_budget_halt,
        condition: fn %{budget_decision: %{action: :halt}} -> true end,
        reaction: fn bundle -> budget_terminal_decision(bundle, :pre_tool_budget) end
      )
    ]
  end

  defp tool_budget_pause_state_step do
    Runic.step(
      fn %{state: %State{} = state, budget_decision: %{action: action}} = bundle ->
        case action do
          value when value in [:review, :wait] ->
            State.with_pending_action!(state, budget_pause_action(bundle, :pre_tool_budget))

          _ ->
            nil
        end
      end,
      name: :set_tool_budget_pause_state
    )
  end

  defp tool_budget_terminal_state_step do
    Runic.step(
      fn %{state: %State{} = state, budget_decision: %{action: action}} = bundle ->
        case action do
          :halt ->
            decision = budget_terminal_decision(bundle, :pre_tool_budget)
            apply_terminal_decision(record_last_control_decision(state, decision), decision)

          _ ->
            nil
        end
      end,
      name: :set_tool_budget_terminal_state
    )
  end

  defp pre_tool_guard_step(opts) do
    Runic.step(
      fn %{state: state, turn_result: turn_result, execution_plan: execution_plan} = bundle ->
        guard_request =
          GuardRequest.new!(
            :pre_tool,
            state,
            turn_result: turn_result,
            execution_plan: execution_plan,
            subject: execution_plan,
            policy: Keyword.get(opts, :pre_tool_guard_policy),
            metadata: %{guard_point: :pre_tool}
          )

        guard_decision =
          EvaluateGuard.evaluate!(
            guard_request,
            evaluator: Keyword.get(opts, :pre_tool_guard)
          )

        bundle
        |> Map.put(:guard_request, guard_request)
        |> Map.put(:guard_decision, guard_decision)
      end,
      name: :pre_tool_guard
    )
  end

  defp pre_tool_guard_rules do
    [
      Runic.rule(
        name: :pre_tool_guard_continue,
        condition: fn %{guard_decision: %{action: action, replacement: replacement}} ->
          action == :allow or (action == :rewrite and not is_nil(replacement))
        end,
        reaction: fn bundle ->
          Map.put(bundle, :execution_plan, resolved_guard_subject(bundle))
        end
      ),
      Runic.rule(
        name: :pre_tool_guard_review,
        condition: fn %{guard_decision: %{action: :review}} -> true end,
        reaction: fn bundle -> guard_pause_action(bundle) end
      ),
      Runic.rule(
        name: :pre_tool_guard_wait,
        condition: fn %{guard_decision: %{action: :wait}} -> true end,
        reaction: fn bundle -> guard_pause_action(bundle) end
      ),
      Runic.rule(
        name: :pre_tool_guard_deny,
        condition: fn %{guard_decision: %{action: action, replacement: replacement}} ->
          action == :deny or (action == :rewrite and is_nil(replacement))
        end,
        reaction: fn bundle -> guard_terminal_decision(bundle) end
      )
    ]
  end

  defp pre_tool_guard_pause_state_step do
    Runic.step(
      fn %{state: %State{} = state, guard_decision: %{action: action}} = bundle ->
        case action do
          value when value in [:review, :wait] ->
            State.with_pending_action!(state, guard_pause_action(bundle))

          _ ->
            nil
        end
      end,
      name: :set_pre_tool_guard_pause_state
    )
  end

  defp pre_tool_guard_terminal_state_step do
    Runic.step(
      fn %{state: %State{} = state, guard_decision: %{action: action, replacement: replacement}} =
           bundle ->
        cond do
          action == :deny ->
            decision = guard_terminal_decision(bundle)
            apply_terminal_decision(record_last_control_decision(state, decision), decision)

          action == :rewrite and is_nil(replacement) ->
            decision = guard_terminal_decision(bundle)
            apply_terminal_decision(record_last_control_decision(state, decision), decision)

          true ->
            nil
        end
      end,
      name: :set_pre_tool_guard_terminal_state
    )
  end

  defp execute_tool_lane_step(opts) do
    Runic.step(
      fn %{
           state: state,
           turn_result: turn_result,
           execution_plan: execution_plan,
           selection: selection
         } =
           bundle ->
        batch_result =
          ExecuteToolCallsControlled.execute!(
            execution_plan,
            selection,
            retry_policy: Keyword.get(opts, :tool_retry_policy),
            fallback_policy: Keyword.get(opts, :tool_fallback_policy)
          )

        Map.merge(bundle, %{state: state, turn_result: turn_result, batch_result: batch_result})
      end,
      name: :execute_tool_lane
    )
  end

  defp append_tool_lane_step do
    Runic.step(
      fn %{state: state, execution_plan: execution_plan, batch_result: batch_result} = bundle ->
        updated_state = AppendToolObservations.append!(state, execution_plan, batch_result)
        %{bundle | state: updated_state}
      end,
      name: :append_tool_lane
    )
  end

  defp prepare_answer_lane_step do
    Runic.step(
      fn %{turn_request: turn_request, turn_result: turn_result} = bundle ->
        projected_state = State.apply_turn_result!(turn_request.state, turn_request, turn_result)
        Map.put(bundle, :projected_state, projected_state)
      end,
      name: :prepare_answer_lane
    )
  end

  defp answer_budget_step(opts) do
    Runic.step(
      fn %{projected_state: projected_state, turn_result: turn_result, runtime: runtime} = bundle ->
        decision =
          EvaluateBudget.evaluate!(
            %{state: projected_state, turn_result: turn_result, runtime: runtime},
            budget_policy: Keyword.get(opts, :budget_policy)
          )

        bundle
        |> Map.put(:subject, turn_result)
        |> Map.put(:budget_decision, decision)
      end,
      name: :answer_budget
    )
  end

  defp answer_budget_rules do
    [
      Runic.rule(
        name: :answer_budget_continue,
        condition: fn %{budget_decision: %{action: :continue}} -> true end,
        reaction: & &1
      ),
      Runic.rule(
        name: :answer_budget_review,
        condition: fn %{budget_decision: %{action: :review}} -> true end,
        reaction: fn bundle -> budget_pause_action(bundle, :pre_answer_budget) end
      ),
      Runic.rule(
        name: :answer_budget_wait,
        condition: fn %{budget_decision: %{action: :wait}} -> true end,
        reaction: fn bundle -> budget_pause_action(bundle, :pre_answer_budget) end
      ),
      Runic.rule(
        name: :answer_budget_halt,
        condition: fn %{budget_decision: %{action: :halt}} -> true end,
        reaction: fn bundle -> budget_terminal_decision(bundle, :pre_answer_budget) end
      )
    ]
  end

  defp answer_budget_pause_state_step do
    Runic.step(
      fn %{budget_decision: %{action: action}} = bundle ->
        case action do
          value when value in [:review, :wait] ->
            bundle
            |> answer_state_from_bundle()
            |> State.with_pending_action!(budget_pause_action(bundle, :pre_answer_budget))

          _ ->
            nil
        end
      end,
      name: :set_answer_budget_pause_state
    )
  end

  defp answer_budget_terminal_state_step do
    Runic.step(
      fn %{budget_decision: %{action: action}} = bundle ->
        case action do
          :halt ->
            decision = budget_terminal_decision(bundle, :pre_answer_budget)

            bundle
            |> answer_state_from_bundle()
            |> record_last_control_decision(decision)
            |> apply_terminal_decision(decision)

          _ ->
            nil
        end
      end,
      name: :set_answer_budget_terminal_state
    )
  end

  defp pre_answer_guard_step(opts) do
    Runic.step(
      fn %{projected_state: projected_state, turn_result: turn_result} = bundle ->
        guard_request =
          GuardRequest.new!(
            :pre_answer,
            projected_state,
            turn_result: turn_result,
            subject: turn_result,
            candidate_message: turn_result.message,
            policy: Keyword.get(opts, :pre_answer_guard_policy),
            metadata: %{guard_point: :pre_answer}
          )

        guard_decision =
          EvaluateGuard.evaluate!(
            guard_request,
            evaluator: Keyword.get(opts, :pre_answer_guard)
          )

        bundle
        |> Map.put(:guard_request, guard_request)
        |> Map.put(:guard_decision, guard_decision)
      end,
      name: :pre_answer_guard
    )
  end

  defp pre_answer_guard_rules do
    [
      Runic.rule(
        name: :pre_answer_guard_continue,
        condition: fn %{guard_decision: %{action: action, replacement: replacement}} ->
          action == :allow or (action == :rewrite and not is_nil(replacement))
        end,
        reaction: fn bundle ->
          Map.put(bundle, :resolved_turn_result, resolved_guard_subject(bundle))
        end
      ),
      Runic.rule(
        name: :pre_answer_guard_review,
        condition: fn %{guard_decision: %{action: :review}} -> true end,
        reaction: fn bundle -> guard_pause_action(bundle) end
      ),
      Runic.rule(
        name: :pre_answer_guard_wait,
        condition: fn %{guard_decision: %{action: :wait}} -> true end,
        reaction: fn bundle -> guard_pause_action(bundle) end
      ),
      Runic.rule(
        name: :pre_answer_guard_deny,
        condition: fn %{guard_decision: %{action: action, replacement: replacement}} ->
          action == :deny or (action == :rewrite and is_nil(replacement))
        end,
        reaction: fn bundle -> guard_terminal_decision(bundle) end
      )
    ]
  end

  defp pre_answer_guard_pause_state_step do
    Runic.step(
      fn %{guard_decision: %{action: action}} = bundle ->
        case action do
          value when value in [:review, :wait] ->
            bundle
            |> answer_state_from_bundle()
            |> State.with_pending_action!(guard_pause_action(bundle))

          _ ->
            nil
        end
      end,
      name: :set_pre_answer_guard_pause_state
    )
  end

  defp pre_answer_guard_terminal_state_step do
    Runic.step(
      fn %{guard_decision: %{action: action, replacement: replacement}} = bundle ->
        cond do
          action == :deny ->
            decision = guard_terminal_decision(bundle)

            bundle
            |> answer_state_from_bundle()
            |> record_last_control_decision(decision)
            |> apply_terminal_decision(decision)

          action == :rewrite and is_nil(replacement) ->
            decision = guard_terminal_decision(bundle)

            bundle
            |> answer_state_from_bundle()
            |> record_last_control_decision(decision)
            |> apply_terminal_decision(decision)

          true ->
            nil
        end
      end,
      name: :set_pre_answer_guard_terminal_state
    )
  end

  defp update_answer_lane_step do
    Runic.step(
      fn %{turn_request: turn_request, resolved_turn_result: resolved_turn_result} = bundle ->
        state = State.apply_turn_result!(turn_request.state, turn_request, resolved_turn_result)
        Map.merge(bundle, %{state: state, turn_result: resolved_turn_result})
      end,
      name: :update_answer_lane
    )
  end

  defp continue_step(name, opts) do
    Runic.step(
      fn %State{} = state, %TurnResult{} = turn_result ->
        ContinueChat.decide!(state, turn_result, opts)
      end,
      name: name
    )
  end

  defp project_field_step(name, field) do
    Runic.step(
      fn bundle ->
        Map.fetch!(bundle, field)
      end,
      name: name
    )
  end

  defp budget_pause_action(
         %{
           state: %State{} = state,
           subject: subject,
           budget_decision: %{action: :review} = decision
         },
         checkpoint
       ) do
    ReviewRequest.new!(
      :budget_review,
      checkpoint: checkpoint,
      resume_key: pause_resume_key(:review, checkpoint, subject, state),
      subject: subject,
      details: %{budget_decision: decision},
      metadata: %{checkpoint: checkpoint}
    )
  end

  defp budget_pause_action(
         %{state: %State{} = state, subject: subject, budget_decision: decision},
         checkpoint
       ) do
    Wait.new!(
      :budget,
      reason: :budget_exhausted,
      resume_key: pause_resume_key(:wait, checkpoint, subject, state),
      payload: %{subject: subject, budget_decision: decision},
      details: %{budget_decision: decision},
      metadata: %{checkpoint: checkpoint}
    )
  end

  defp budget_terminal_decision(%{budget_decision: decision}, checkpoint) do
    ContinueDecision.halt!(:budget_exhausted,
      metadata: %{checkpoint: checkpoint, reasons: decision.reasons}
    )
  end

  defp guard_pause_action(%{
         guard_request: request,
         guard_decision: %{action: :review} = decision
       }) do
    ReviewRequest.new!(
      :guard_review,
      checkpoint: request.point,
      resume_key: pause_resume_key(:review, request.point, request.subject, request.state),
      subject: request.subject,
      details: %{guard_request: request, guard_decision: decision},
      metadata: %{guard_point: request.point}
    )
  end

  defp guard_pause_action(%{guard_request: request, guard_decision: decision}) do
    Wait.new!(
      :guard,
      reason: decision.reason,
      resume_key: pause_resume_key(:wait, request.point, request.subject, request.state),
      payload: %{subject: request.subject, guard_request: request},
      details: %{guard_request: request, guard_decision: decision},
      metadata: %{guard_point: request.point}
    )
  end

  defp guard_terminal_decision(%{
         guard_request: request,
         guard_decision: %GuardDecision{action: :rewrite}
       }) do
    ContinueDecision.halt!(:guard_invalid_rewrite, metadata: %{guard_point: request.point})
  end

  defp guard_terminal_decision(%{guard_request: request, guard_decision: decision}) do
    ContinueDecision.halt!(:guard_denied,
      metadata: %{guard_point: request.point, reason: decision.reason}
    )
  end

  defp resolved_guard_subject(%{
         guard_request: request,
         guard_decision: %GuardDecision{action: :allow}
       }),
       do: request.subject

  defp resolved_guard_subject(%{guard_decision: %GuardDecision{replacement: replacement}}),
    do: replacement

  defp answer_state_from_bundle(%{turn_request: turn_request, projected_state: projected_state}) do
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

  defp record_last_control_decision(%State{} = state, %ContinueDecision{} = decision) do
    metadata = Map.put(state.metadata || %{}, :last_control_decision, decision)
    %State{state | metadata: metadata}
  end

  defp apply_terminal_decision(%State{} = state, %ContinueDecision{action: :halt}),
    do: State.with_status!(state, :halted)

  defp apply_terminal_decision(%State{} = state, %ContinueDecision{action: :stop}),
    do: State.with_status!(state, :completed)

  defp apply_terminal_decision(%State{} = state, %ContinueDecision{}), do: state

  defp pause_resume_key(kind, checkpoint, subject, %State{} = state) do
    hash =
      :erlang.phash2({
        kind,
        checkpoint,
        subject,
        state.conversation.turns,
        state.last_turn_result,
        state.metadata
      })

    "#{kind}:#{checkpoint}:#{hash}"
  end
end
