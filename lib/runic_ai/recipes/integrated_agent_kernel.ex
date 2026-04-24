defmodule RunicAI.Recipes.IntegratedAgentKernel do
  @moduledoc """
  Generic workflow-owned integrated runtime kernel.
  """

  require Runic

  alias Runic.Component
  alias Runic.Workflow
  alias RunicAI.Integrated.Emission
  alias RunicAI.Integrated.RuntimeState
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Steps.EmitIntegratedValue
  alias RunicAI.Steps.NormalizeIntegratedSignal
  alias RunicAI.Steps.SelectReadyAgent

  @spec new(keyword()) :: Workflow.t()
  def new(opts) when is_list(opts) do
    processor = Keyword.fetch!(opts, :processor)

    normalize_signal_step =
      NormalizeIntegratedSignal.new(
        name: :normalize_integrated_signal,
        default_agent_id: Keyword.get(opts, :default_agent_id)
      )

    runtime_accumulator =
      Runic.accumulator(
        initial_runtime(opts),
        fn input, %RuntimeState{} = runtime_state ->
          RuntimeState.reduce!(runtime_state, input,
            default_agent_id: Keyword.get(opts, :default_agent_id),
            session_builder: Keyword.get(opts, :session_builder)
          )
        end,
        name: :integrated_runtime
      )

    route_ready_rule =
      Runic.rule(
        name: :route_ready_integrated_agent,
        condition: fn _runtime_state ->
          RuntimeState.ready?(state_of(:integrated_runtime))
        end,
        reaction: fn _runtime_state ->
          state_of(:integrated_runtime)
        end
      )

    select_ready_step = SelectReadyAgent.new(name: :select_ready_agent)

    process_lane_step =
      Runic.step(
        fn bundle ->
          processor.(bundle)
        end,
        name: :process_integrated_lane
      )

    emit_values_step = EmitIntegratedValue.new(name: :emit_integrated_value)

    emission_accumulator =
      Runic.accumulator(
        [],
        fn emissions, acc ->
          acc ++ normalize_emissions(emissions)
        end,
        name: :integrated_emissions
      )

    Workflow.new(name: Keyword.get(opts, :name, :integrated_agent_kernel))
    |> Workflow.add(normalize_signal_step)
    |> Workflow.add(runtime_accumulator, to: :normalize_integrated_signal)
    |> Workflow.add(route_ready_rule, to: :integrated_runtime)
    |> Workflow.add(select_ready_step, to: :route_ready_integrated_agent)
    |> Workflow.add(process_lane_step, to: :select_ready_agent)
    |> then(fn workflow ->
      workflow = Component.connect(runtime_accumulator, process_lane_step, workflow)

      workflow
      |> Workflow.add(emit_values_step, to: :process_integrated_lane)
      |> Workflow.add(emission_accumulator, to: :emit_integrated_value)
    end)
  end

  @spec runtime_state(Workflow.t()) :: RuntimeState.t() | nil
  def runtime_state(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions(:integrated_runtime)
    |> Enum.filter(&match?(%RuntimeState{}, &1))
    |> Enum.max_by(&runtime_score/1, fn -> nil end)
  end

  @spec session(Workflow.t(), String.t() | atom()) :: SessionState.t() | nil
  def session(%Workflow{} = workflow, agent_id) when is_atom(agent_id) do
    session(workflow, Atom.to_string(agent_id))
  end

  def session(%Workflow{} = workflow, agent_id) when is_binary(agent_id) do
    workflow
    |> runtime_state()
    |> case do
      %RuntimeState{agents: agents} -> Map.get(agents, agent_id)
      _ -> nil
    end
  end

  @spec emissions(Workflow.t()) :: [Emission.t()]
  def emissions(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions(:integrated_emissions)
    |> Enum.filter(&is_list/1)
    |> Enum.max_by(&length/1, fn -> [] end)
  end

  @spec latest_emission(Workflow.t()) :: Emission.t() | nil
  def latest_emission(%Workflow{} = workflow) do
    workflow
    |> emissions()
    |> List.last()
  end

  # Cyclic workflows can leave `Workflow.results/2` pointing at an older
  # accumulator production, so choose the most advanced raw runtime snapshot.
  defp runtime_score(%RuntimeState{
         agents: agents,
         ready_queue: ready_queue,
         resume_index: resume_index
       }) do
    agent_progress =
      Enum.reduce(agents, 0, fn {_agent_id, session}, acc ->
        acc +
          session.agent_state.conversation.turns * 100 +
          Map.get(session.control, :attempts, 0) * 10 +
          length(session.inbox)
      end)

    agent_progress + length(ready_queue) + map_size(resume_index)
  end

  defp initial_runtime(opts) do
    Keyword.get(opts, :initial_runtime) ||
      RuntimeState.new!(
        agents: Keyword.get(opts, :initial_agents, []),
        metadata: %{default_agent_id: Keyword.get(opts, :default_agent_id)}
      )
  end

  defp normalize_emissions(emissions) when is_list(emissions) do
    Enum.filter(emissions, &match?(%Emission{}, &1))
  end

  defp normalize_emissions(%Emission{} = emission), do: [emission]
  defp normalize_emissions(_other), do: []
end
