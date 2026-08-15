defmodule RunicAI.Recipes.ChatAgentKernel do
  @moduledoc """
  Reference conversational kernel workflow built from RunicAI components.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Message
  alias RunicAI.Rules.ContinueChat
  alias RunicAI.Steps.AssembleTurnPrompt
  alias RunicAI.Steps.AssembleTurnRequest
  alias RunicAI.Steps.GenerateTurn
  alias RunicAI.Steps.InterpretTurn

  @spec new(keyword()) :: Workflow.t()
  def new(opts \\ []) do
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

    prompt_step = AssembleTurnPrompt.new(name: :assemble_turn_prompt)
    generate_step = GenerateTurn.new(name: :generate_turn)

    interpret_step =
      InterpretTurn.new(
        name: :interpret_turn,
        final_pattern: Keyword.get(opts, :final_pattern),
        final_when: Keyword.get(opts, :final_when)
      )

    update_state_step =
      Runic.step(
        fn %TurnRequest{} = turn_request, %TurnResult{} = turn_result ->
          State.apply_turn_result!(turn_request.state, turn_request, turn_result)
        end,
        name: :update_agent_state
      )

    continue_input_step = ContinueChat.input_step(name: :continue_chat_input)

    continue_rules =
      ContinueChat.rules(
        name: :continue_chat,
        max_turns: Keyword.get(opts, :max_turns),
        stop_pattern: Keyword.get(opts, :stop_pattern),
        continue_when: Keyword.get(opts, :continue_when)
      )

    Workflow.new(name: Keyword.get(opts, :name, :chat_agent_kernel))
    |> Workflow.add(request_step)
    |> Workflow.add(prompt_step, to: :assemble_turn_request)
    |> Workflow.add(generate_step, to: [:assemble_turn_request, :assemble_turn_prompt])
    |> Workflow.add(interpret_step, to: :generate_turn)
    |> Workflow.add(update_state_step, to: [:assemble_turn_request, :interpret_turn])
    |> Workflow.add(continue_input_step, to: [:update_agent_state, :interpret_turn])
    |> add_rules(continue_rules, :continue_chat_input)
  end

  @spec latest_state(Workflow.t()) :: State.t() | nil
  def latest_state(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%State{}, &1))
    |> List.last()
  end

  @spec latest_turn_result(Workflow.t()) :: TurnResult.t() | nil
  def latest_turn_result(%Workflow{} = workflow) do
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

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    State.new!(
      system: Keyword.get(opts, :system),
      messages: Keyword.get(opts, :messages),
      assigns: Keyword.get(opts, :assigns, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec latest_reply_text(Workflow.t()) :: String.t() | nil
  def latest_reply_text(%Workflow{} = workflow) do
    case latest_turn_result(workflow) do
      %TurnResult{message: %Message{} = message} -> message.content
      _ -> nil
    end
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
