defmodule RunicAI.Steps.GenerateTurnControlled do
  @moduledoc """
  Generate one conversational turn with retry and fallback control policies.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Control.Recovery
  alias RunicAI.Error
  alias RunicAI.LLM.Retry
  alias RunicAI.LLM.Result
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
      retryable?: &recoverable_outcome?(&1, turn_request),
      fallback?: &fallback_outcome?(&1, turn_request),
      run_fallback: fn alternate, _outcome ->
        run_alternate(turn_request, prompt, alternate, opts)
      end
    )
  end

  defp run_alternate(%TurnRequest{} = turn_request, %Prompt{} = prompt, alternate, _opts)
       when is_function(alternate, 2) do
    turn_request
    |> alternate.(prompt)
    |> annotate_fallback(turn_request.model, nil)
  end

  defp run_alternate(%TurnRequest{} = turn_request, %Prompt{} = prompt, {model, llm_opts}, _opts)
       when is_list(llm_opts) do
    updated_turn_request = %{
      turn_request
      | model: model,
        llm_opts: Keyword.merge(turn_request.llm_opts, llm_opts)
    }

    updated_turn_request
    |> GenerateTurn.generate(prompt)
    |> annotate_fallback(turn_request.model, model)
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

    updated_turn_request
    |> GenerateTurn.generate(prompt)
    |> annotate_fallback(turn_request.model, model)
  end

  defp run_alternate(%TurnRequest{} = turn_request, %Prompt{} = prompt, alternate_model, _opts) do
    updated_turn_request = %{turn_request | model: alternate_model}

    updated_turn_request
    |> GenerateTurn.generate(prompt)
    |> annotate_fallback(turn_request.model, alternate_model)
  end

  defp recoverable_outcome?({:retry, _reason}, _turn_request), do: true
  defp recoverable_outcome?({:error, %Error{retryable?: true}}, _turn_request), do: true

  defp recoverable_outcome?({:ok, %Result{} = result}, %TurnRequest{} = turn_request),
    do: required_tool_without_call?(result, turn_request)

  defp recoverable_outcome?(_outcome, _turn_request), do: false

  defp fallback_outcome?({:error, %Error{} = error}, _turn_request),
    do: not Retry.permanent_provider_failure?(error)

  defp fallback_outcome?({:error, _reason}, _turn_request), do: true
  defp fallback_outcome?({:retry, _reason}, _turn_request), do: true

  defp fallback_outcome?({:ok, %Result{} = result}, %TurnRequest{} = turn_request),
    do: required_tool_without_call?(result, turn_request)

  defp fallback_outcome?(_outcome, _turn_request), do: false

  defp required_tool_without_call?(%Result{} = result, %TurnRequest{} = turn_request) do
    Keyword.get(turn_request.llm_opts, :tool_choice) in [:required, "required"] and
      not prior_tool_observation?(turn_request) and
      Map.get(Result.evidence(result), :tool_call_count, 0) == 0
  end

  defp prior_tool_observation?(%TurnRequest{} = turn_request) do
    Enum.any?(turn_request.state.conversation.messages, &match?(%{role: :tool}, &1)) or
      Enum.any?(turn_request.observations, &match?(%{role: :tool}, &1))
  end

  defp annotate_fallback({:ok, %Result{} = result}, primary_model, alternate_model) do
    evidence =
      result
      |> Result.evidence()
      |> Map.merge(%{
        fallback?: true,
        primary_model: primary_model,
        fallback_model: alternate_model
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, %{result | metadata: Map.put(result.metadata, :generation_evidence, evidence)}}
  end

  defp annotate_fallback({tag, %Error{} = error}, primary_model, alternate_model)
       when tag in [:error, :retry] do
    details =
      error.details
      |> Map.put(:fallback?, true)
      |> Map.put(:primary_model, primary_model)
      |> maybe_put(:fallback_model, alternate_model)

    {tag, %{error | details: details}}
  end

  defp annotate_fallback(outcome, _primary_model, _alternate_model), do: outcome

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
