defmodule RunicAI.Recipes.HandoffContextBuilder do
  @moduledoc """
  Workflow that ingests current state into the context graph and produces a
  focused handoff artifact.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Context.Focus
  alias RunicAI.Context.HandoffArtifact
  alias RunicAI.Steps.BuildHandoff
  alias RunicAI.Steps.InferFocus
  alias RunicAI.Steps.IngestContextTurn

  @spec new(keyword()) :: Workflow.t()
  def new(opts \\ []) do
    state_step =
      Runic.step(
        fn input ->
          Map.get(input, :state) || initial_state(opts)
        end,
        name: :handoff_state
      )

    synthetic_turn_request_step =
      Runic.step(
        fn %State{} = state ->
          TurnRequest.new!(state, model: Keyword.get(opts, :model, "handoff:none"))
        end,
        name: :handoff_turn_request
      )

    explicit_focus_step =
      Runic.step(
        fn input ->
          Map.get(input, :handoff_request) || Map.get(input, :focus) || Map.get(input, :goal)
        end,
        name: :handoff_request_input
      )

    ingest_step = IngestContextTurn.new(name: :ingest_context_turn)

    focus_step =
      InferFocus.new(name: :infer_focus, default_goal: "continue the work in a new thread")

    project_state_step =
      Runic.step(fn %TurnRequest{} = turn_request -> turn_request.state end,
        name: :ingested_state
      )

    resolved_request_step =
      Runic.step(
        fn request_input, %Focus{} = focus ->
          request_input || focus
        end,
        name: :resolved_handoff_request
      )

    build_step =
      BuildHandoff.new(
        name: :build_handoff,
        include_refs?: Keyword.get(opts, :include_refs?, true)
      )

    Workflow.new(name: Keyword.get(opts, :name, :handoff_context_builder))
    |> Workflow.add(state_step)
    |> Workflow.add(synthetic_turn_request_step, to: :handoff_state)
    |> Workflow.add(explicit_focus_step)
    |> Workflow.add(ingest_step, to: :handoff_turn_request)
    |> Workflow.add(focus_step, to: [:ingest_context_turn, :handoff_request_input])
    |> Workflow.add(project_state_step, to: :ingest_context_turn)
    |> Workflow.add(resolved_request_step, to: [:handoff_request_input, :infer_focus])
    |> Workflow.add(build_step, to: [:ingested_state, :resolved_handoff_request])
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

  @spec latest_focus(Workflow.t()) :: Focus.t() | nil
  def latest_focus(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%Focus{}, &1))
    |> List.last()
  end

  @spec latest_handoff(Workflow.t()) :: HandoffArtifact.t() | nil
  def latest_handoff(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%HandoffArtifact{}, &1))
    |> List.last()
  end
end
