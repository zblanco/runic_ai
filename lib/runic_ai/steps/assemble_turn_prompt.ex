defmodule RunicAI.Steps.AssembleTurnPrompt do
  @moduledoc """
  Assemble a prompt for one conversational turn from a normalized turn request.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Prompt
  alias RunicAI.Steps.RepairHistory

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :assemble_turn_prompt)

    Runic.step(
      fn %TurnRequest{} = turn_request ->
        build_prompt(turn_request)
      end,
      name: name
    )
  end

  @spec build_prompt(TurnRequest.t()) :: Prompt.t()
  def build_prompt(%TurnRequest{} = turn_request) do
    turn_request
    |> TurnRequest.prompt_messages()
    |> RepairHistory.repair_messages!()
    |> Prompt.new!(metadata: turn_request.metadata)
  end
end
