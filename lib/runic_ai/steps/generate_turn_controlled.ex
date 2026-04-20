defmodule RunicAI.Steps.GenerateTurnControlled do
  @moduledoc """
  Generate one conversational turn with retry and fallback control policies.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Control.Recovery
  alias RunicAI.Prompt
  alias RunicAI.Steps.GenerateTurn

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :generate_turn_controlled)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnRequest{} = turn_request, %Prompt{} = prompt ->
        generate(turn_request, prompt, options)
      end,
      name: name
    )
  end

  @spec generate(TurnRequest.t(), Prompt.t(), keyword()) :: term()
  def generate(%TurnRequest{} = turn_request, %Prompt{} = prompt, opts \\ []) do
    Recovery.run(
      fn ->
        GenerateTurn.generate(turn_request, prompt)
      end,
      retry_policy: Keyword.get(opts, :retry_policy),
      fallback_policy: Keyword.get(opts, :fallback_policy),
      run_fallback: fn alternate, _outcome ->
        run_alternate(turn_request, prompt, alternate, opts)
      end
    )
  end

  defp run_alternate(%TurnRequest{} = turn_request, %Prompt{} = prompt, alternate, _opts)
       when is_function(alternate, 2) do
    alternate.(turn_request, prompt)
  end

  defp run_alternate(%TurnRequest{} = turn_request, %Prompt{} = prompt, {model, llm_opts}, _opts)
       when is_list(llm_opts) do
    updated_turn_request = %{
      turn_request
      | model: model,
        llm_opts: Keyword.merge(turn_request.llm_opts, llm_opts)
    }

    GenerateTurn.generate(updated_turn_request, prompt)
  end

  defp run_alternate(
         %TurnRequest{} = turn_request,
         %Prompt{} = prompt,
         %{model: model} = alternate,
         _opts
       ) do
    updated_turn_request =
      %{
        turn_request
        | model: model,
          llm_opts: Keyword.merge(turn_request.llm_opts, Map.get(alternate, :llm_opts, []))
      }

    GenerateTurn.generate(updated_turn_request, prompt)
  end

  defp run_alternate(%TurnRequest{} = turn_request, %Prompt{} = prompt, alternate_model, _opts) do
    updated_turn_request = %{turn_request | model: alternate_model}
    GenerateTurn.generate(updated_turn_request, prompt)
  end
end
