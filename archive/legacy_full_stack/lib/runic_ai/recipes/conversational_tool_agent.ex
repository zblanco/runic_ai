defmodule RunicAI.Recipes.ConversationalToolAgent do
  @moduledoc """
  Reference conversational tool agent workflow built from RunicAI components.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Message
  alias RunicAI.Recipes.ChatAgentKernel
  alias RunicAI.Rules.ContinueChat
  alias RunicAI.Steps.AppendToolObservations
  alias RunicAI.Steps.AssembleTurnPrompt
  alias RunicAI.Steps.AssembleTurnRequest
  alias RunicAI.Steps.AttachVisibleTools
  alias RunicAI.Steps.ExecuteToolCalls
  alias RunicAI.Steps.GenerateTurn
  alias RunicAI.Steps.InterpretToolRequests
  alias RunicAI.Steps.InterpretTurn
  alias RunicAI.Steps.PlanToolExecution
  alias RunicAI.Steps.ReduceToolResults
  alias RunicAI.Steps.SelectTools
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Tool.Observation
  alias RunicAI.Tool.RequirementPolicy
  alias RunicAI.Tool.Selection

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
    generate_step = GenerateTurn.new(name: :generate_turn)

    interpret_step =
      InterpretTurn.new(
        name: :interpret_turn,
        final_pattern: Keyword.get(opts, :final_pattern),
        final_when: Keyword.get(opts, :final_when)
      )

    interpret_tool_requests_step = InterpretToolRequests.new(name: :interpret_tool_requests)

    update_state_step =
      Runic.step(
        fn %TurnRequest{} = turn_request, %TurnResult{} = turn_result ->
          State.apply_turn_result!(turn_request.state, turn_request, turn_result)
        end,
        name: :update_agent_state
      )

    plan_step =
      PlanToolExecution.new(
        name: :plan_tool_execution,
        execution_policy: Keyword.get(opts, :execution_policy),
        planner: Keyword.get(opts, :tool_planner)
      )

    execute_input_step = ExecuteToolCalls.input_step(name: :execute_tool_calls_input)
    execute_step = ExecuteToolCalls.new(name: :execute_tool_calls)
    reduce_step = ReduceToolResults.new(name: :reduce_tool_results)
    append_step = AppendToolObservations.new(name: :append_tool_observations)

    continue_input_step = ContinueChat.input_step(name: :continue_chat_input)

    continue_rules =
      ContinueChat.rules(
        name: :continue_chat,
        max_turns: Keyword.get(opts, :max_turns),
        stop_pattern: Keyword.get(opts, :stop_pattern),
        continue_when: Keyword.get(opts, :continue_when)
      )

    Workflow.new(name: Keyword.get(opts, :name, :conversational_tool_agent))
    |> Workflow.add(request_step)
    |> Workflow.add(selection_step, to: :assemble_turn_request)
    |> Workflow.add(prompt_step, to: :assemble_turn_request)
    |> Workflow.add(attach_tools_step, to: [:assemble_turn_request, :select_tools])
    |> Workflow.add(generate_step, to: [:attach_visible_tools, :assemble_turn_prompt])
    |> Workflow.add(interpret_step, to: :generate_turn)
    |> Workflow.add(interpret_tool_requests_step, to: [:interpret_turn, :select_tools])
    |> Workflow.add(update_state_step, to: [:assemble_turn_request, :interpret_tool_requests])
    |> Workflow.add(plan_step, to: [:interpret_tool_requests, :select_tools])
    |> Workflow.add(execute_input_step, to: [:plan_tool_execution, :select_tools])
    |> Workflow.add(execute_step, to: :execute_tool_calls_input)
    |> Workflow.add(reduce_step, to: [:plan_tool_execution, :execute_tool_calls])
    |> Workflow.add(append_step,
      to: [:update_agent_state, :plan_tool_execution, :reduce_tool_results]
    )
    |> Workflow.add(continue_input_step,
      to: [:append_tool_observations, :interpret_tool_requests]
    )
    |> add_rules(continue_rules, :continue_chat_input)
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []), do: ChatAgentKernel.initial_state(opts)

  @spec latest_state(Workflow.t()) :: State.t() | nil
  def latest_state(%Workflow{} = workflow) do
    latest_from_components(workflow, [:append_tool_observations, :update_agent_state], State) ||
      workflow
      |> Workflow.raw_productions()
      |> Enum.filter(&match?(%State{}, &1))
      |> List.last()
  end

  @spec latest_turn_result(Workflow.t()) :: TurnResult.t() | nil
  def latest_turn_result(%Workflow{} = workflow) do
    latest_from_components(workflow, [:interpret_tool_requests, :interpret_turn], TurnResult) ||
      workflow
      |> Workflow.raw_productions()
      |> Enum.filter(&match?(%TurnResult{}, &1))
      |> List.last()
  end

  @spec latest_continue_decision(Workflow.t()) :: ContinueDecision.t() | nil
  def latest_continue_decision(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%ContinueDecision{}, &1))
    |> List.last()
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
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%ExecutionPlan{}, &1))
    |> List.last()
  end

  @spec latest_tool_results(Workflow.t()) :: [CallResult.t()] | nil
  def latest_tool_results(%Workflow{} = workflow) do
    case latest_struct(workflow, BatchResult) do
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
    workflow =
      new(opts)
      |> Workflow.react_until_satisfied(input, react_opts)

    max_tool_rounds = Keyword.get(opts, :max_tool_rounds, 8)

    case {latest_state(workflow), latest_turn_result(workflow)} do
      {%State{status: :running} = state, %TurnResult{kind: :tool_requests}}
      when depth + 1 < max_tool_rounds ->
        do_react_until_resolution(%{state: state}, opts, react_opts, depth + 1)

      _ ->
        workflow
    end
  end

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

  defp latest_from_components(%Workflow{} = workflow, component_names, module) do
    Enum.find_value(component_names, fn component_name ->
      workflow
      |> Workflow.raw_productions(component_name)
      |> Enum.reverse()
      |> Enum.find(&match?(%{__struct__: ^module}, &1))
    end)
  end

  defp recipe_llm_opts(opts) do
    llm_opts = Keyword.get(opts, :llm_opts, [])

    case Keyword.fetch(opts, :client) do
      {:ok, client} -> Keyword.put(llm_opts, :client, client)
      :error -> llm_opts
    end
  end

  defp add_rules(workflow, rules, parent_name) do
    Enum.reduce(rules, workflow, fn rule, wrk ->
      Workflow.add(wrk, rule, to: parent_name)
    end)
  end
end
