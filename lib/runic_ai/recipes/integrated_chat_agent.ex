defmodule RunicAI.Recipes.IntegratedChatAgent do
  @moduledoc """
  Workflow-owned chat recipe that keeps agent state inside the workflow runtime.
  """

  alias Runic.Workflow
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Message
  alias RunicAI.Recipes.ChatAgentKernel
  alias RunicAI.Recipes.IntegratedAgentKernel
  alias RunicAI.Steps.ApplyIntegratedTurnResult
  alias RunicAI.Steps.AssembleTurnPrompt
  alias RunicAI.Steps.GenerateTurn
  alias RunicAI.Steps.InterpretTurn
  alias RunicAI.Steps.MaterializeIntegratedTurn

  @spec new(keyword()) :: Workflow.t()
  def new(opts \\ []) do
    profiles = build_profiles(opts)
    default_agent_id = default_agent_id(opts, profiles)

    IntegratedAgentKernel.new(
      name: Keyword.get(opts, :name, :integrated_chat_agent),
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

  @spec session(Workflow.t(), String.t() | atom()) :: RunicAI.Integrated.SessionState.t() | nil
  def session(%Workflow{} = workflow, agent_id),
    do: IntegratedAgentKernel.session(workflow, agent_id)

  @spec emissions(Workflow.t()) :: [RunicAI.Integrated.Emission.t()]
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

  defp process_bundle(bundle, opts) do
    materialized = MaterializeIntegratedTurn.materialize!(bundle)
    prompt = AssembleTurnPrompt.build_prompt(materialized.turn_request)
    generation = GenerateTurn.generate(materialized.turn_request, prompt)

    turn_result =
      InterpretTurn.interpret!(generation,
        final_pattern: Keyword.get(opts, :final_pattern),
        final_when: Keyword.get(opts, :final_when)
      )

    ApplyIntegratedTurnResult.apply_result!(materialized, turn_result,
      max_turns: Keyword.get(opts, :max_turns),
      stop_pattern: Keyword.get(opts, :stop_pattern),
      continue_when: Keyword.get(opts, :continue_when)
    )
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
    default_profile(default_opts)
    |> Keyword.merge(profile_opts)
    |> Keyword.put(
      :id,
      normalize_agent_id(
        Keyword.get(profile_opts, :id) || Keyword.get(default_opts, :default_agent_id, "agent")
      )
    )
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
      metadata: Keyword.get(opts, :metadata, %{})
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

    RunicAI.Integrated.SessionState.new!(
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
