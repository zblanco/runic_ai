defmodule RunicAI.Recipes.SummaryBackedChatAgent do
  @moduledoc """
  Reference chat workflow with explicit context ingestion, pressure evaluation,
  summary compaction, memory recall, and retrieval-aware bundle assembly.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Context.Bundle
  alias RunicAI.Context.Focus
  alias RunicAI.Context.PressureDecision
  alias RunicAI.Message
  alias RunicAI.Rules.ContinueChat
  alias RunicAI.Steps.AssembleContextBundle
  alias RunicAI.Steps.AssembleTurnRequest
  alias RunicAI.Steps.CompactContext
  alias RunicAI.Steps.EvaluateContextPressure
  alias RunicAI.Steps.GenerateTurn
  alias RunicAI.Steps.InferFocus
  alias RunicAI.Steps.IngestContextTurn
  alias RunicAI.Steps.InterpretTurn
  alias RunicAI.Steps.RecallMemory
  alias RunicAI.Steps.RetrieveContext
  alias RunicAI.Steps.WriteMemory

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

    explicit_focus_step =
      Runic.step(
        fn input ->
          Map.get(input, :focus) || Map.get(input, :goal)
        end,
        name: :explicit_focus
      )

    ingest_step = IngestContextTurn.new(name: :ingest_context_turn)

    focus_step =
      InferFocus.new(name: :infer_focus, salience_prompt: Keyword.get(opts, :salience_prompt))

    recall_step =
      RecallMemory.new(
        name: :recall_memory,
        store: Keyword.get(opts, :memory_store),
        store_opts: Keyword.get(opts, :memory_store_opts, []),
        limit: Keyword.get(opts, :memory_limit, 6)
      )

    retrieve_step =
      RetrieveContext.new(
        name: :retrieve_context,
        provider: Keyword.get(opts, :retrieval_provider),
        provider_opts: Keyword.get(opts, :retrieval_provider_opts, []),
        top_k: Keyword.get(opts, :retrieval_top_k, 5)
      )

    pressure_step =
      EvaluateContextPressure.new(
        name: :evaluate_context_pressure,
        window_policy: Keyword.get(opts, :window_policy, [])
      )

    compact_step =
      CompactContext.new(
        name: :compact_context,
        policy: Keyword.get(opts, :compaction_policy, []),
        summarizer: Keyword.get(opts, :summarizer)
      )

    bundle_step =
      AssembleContextBundle.new(
        name: :assemble_context_bundle,
        window_policy: Keyword.get(opts, :window_policy, [])
      )

    prompt_step =
      Runic.step(
        fn %Bundle{} = bundle ->
          Bundle.to_prompt!(bundle)
        end,
        name: :bundle_to_prompt
      )

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

    write_memory_step =
      WriteMemory.new(
        name: :write_memory,
        store: Keyword.get(opts, :memory_store),
        store_opts: Keyword.get(opts, :memory_store_opts, [])
      )

    continue_input_step = ContinueChat.input_step(name: :continue_chat_input)

    continue_rules =
      ContinueChat.rules(
        name: :continue_chat,
        max_turns: Keyword.get(opts, :max_turns),
        stop_pattern: Keyword.get(opts, :stop_pattern),
        continue_when: Keyword.get(opts, :continue_when)
      )

    Workflow.new(name: Keyword.get(opts, :name, :summary_backed_chat_agent))
    |> Workflow.add(request_step)
    |> Workflow.add(explicit_focus_step)
    |> Workflow.add(ingest_step, to: :assemble_turn_request)
    |> Workflow.add(focus_step, to: [:ingest_context_turn, :explicit_focus])
    |> Workflow.add(recall_step, to: [:ingest_context_turn, :infer_focus])
    |> Workflow.add(retrieve_step, to: [:ingest_context_turn, :infer_focus])
    |> Workflow.add(pressure_step,
      to: [:ingest_context_turn, :infer_focus, :recall_memory, :retrieve_context]
    )
    |> Workflow.add(compact_step,
      to: [:ingest_context_turn, :infer_focus, :evaluate_context_pressure]
    )
    |> Workflow.add(bundle_step,
      to: [:compact_context, :infer_focus, :recall_memory, :retrieve_context]
    )
    |> Workflow.add(prompt_step, to: :assemble_context_bundle)
    |> Workflow.add(generate_step, to: [:compact_context, :bundle_to_prompt])
    |> Workflow.add(interpret_step, to: :generate_turn)
    |> Workflow.add(update_state_step, to: [:compact_context, :interpret_turn])
    |> Workflow.add(write_memory_step, to: [:update_agent_state, :interpret_turn])
    |> Workflow.add(continue_input_step, to: [:write_memory, :interpret_turn])
    |> add_rules(continue_rules, :continue_chat_input)
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

  @spec latest_focus(Workflow.t()) :: Focus.t() | nil
  def latest_focus(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%Focus{}, &1))
    |> List.last()
  end

  @spec latest_pressure_decision(Workflow.t()) :: PressureDecision.t() | nil
  def latest_pressure_decision(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%PressureDecision{}, &1))
    |> List.last()
  end

  @spec latest_bundle(Workflow.t()) :: Bundle.t() | nil
  def latest_bundle(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%Bundle{}, &1))
    |> List.last()
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
