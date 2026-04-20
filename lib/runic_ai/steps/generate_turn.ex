defmodule RunicAI.Steps.GenerateTurn do
  @moduledoc """
  Generate one conversational turn from a turn request and its assembled prompt.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.LLM
  alias RunicAI.Prompt

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :generate_turn)

    Runic.step(
      fn %TurnRequest{} = turn_request, %Prompt{} = prompt ->
        generate(turn_request, prompt)
      end,
      name: name
    )
  end

  @spec generate(TurnRequest.t(), Prompt.t()) ::
          {:ok, RunicAI.LLM.Result.t()}
          | {:retry, RunicAI.Error.t()}
          | {:error, RunicAI.Error.t()}
  def generate(%TurnRequest{} = turn_request, %Prompt{} = prompt) do
    with {:ok, llm_request} <- TurnRequest.to_llm_request(turn_request, prompt) do
      LLM.generate_text(llm_request)
    end
  end
end
