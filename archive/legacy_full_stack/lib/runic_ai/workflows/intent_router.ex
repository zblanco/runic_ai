defmodule RunicAI.Workflows.IntentRouter do
  @moduledoc """
  Deterministic product routing for direct, reuse, adapt, or draft decisions.

  The router does not ask a model to justify its own cost. It first decides
  whether the request has concrete orchestration signals, then consults the
  activated workflow library with explicit relevance thresholds.
  """

  alias RunicAI.Error
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.WorkflowLibrary

  @workflow_terms MapSet.new(~w[
                    analyze archive batch compare compile coordinate discover each evaluate
                    execute files generate map materialize monitor pipeline process repository
                    research report review schedule sources summarize transform validate verify
                    workflow write
                  ])

  @strategies [:auto, :direct, :workflow]

  @spec route(Store.t(), map() | keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def route(%Store{} = store, request, opts \\ []) when is_list(opts) do
    request = normalize_request(request)
    strategy = Keyword.get(opts, :strategy, :auto)

    with :ok <- validate_request(request),
         :ok <- validate_strategy(strategy) do
      retrieval_opts =
        Keyword.take(opts, [:limit, :exact_similarity, :adapt_similarity])

      retrieval =
        WorkflowLibrary.retrieve(
          store,
          request.objective,
          retrieval_input(request),
          retrieval_opts
        )

      decision(strategy, request, retrieval)
    end
  end

  defp decision(:direct, request, retrieval) do
    {:ok, result(:direct, request, retrieval, [:explicit_direct_strategy])}
  end

  defp decision(:auto, request, retrieval) do
    if orchestration_required?(request) do
      workflow_decision(request, retrieval)
    else
      {:ok,
       result(:direct, request, retrieval, [
         :no_declared_artifact_or_structured_input,
         :no_orchestration_intent_signal
       ])}
    end
  end

  defp decision(:workflow, request, retrieval), do: workflow_decision(request, retrieval)

  defp workflow_decision(request, %{decision: :reuse_exact} = retrieval) do
    {:ok, result(:reuse_exact, request, retrieval, [:relevant_compatible_active_revision])}
  end

  defp workflow_decision(request, %{decision: :adapt} = retrieval) do
    {:ok, result(:adapt, request, retrieval, [:nearby_compatible_active_revision])}
  end

  defp workflow_decision(request, retrieval) do
    {:ok, result(:draft, request, retrieval, [:no_relevant_compatible_active_revision])}
  end

  defp result(strategy, request, retrieval, reasons) do
    %{
      strategy: strategy,
      objective: request.objective,
      request: request,
      selected: retrieval.selected,
      candidates: retrieval.candidates,
      retrieval: retrieval,
      reasons: reasons,
      rationale: rationale(strategy, retrieval)
    }
  end

  defp rationale(:direct, _retrieval) do
    "use a direct response because the request has no concrete orchestration signal"
  end

  defp rationale(:reuse_exact, retrieval), do: retrieval.rationale
  defp rationale(:adapt, retrieval), do: retrieval.rationale

  defp rationale(:draft, _retrieval) do
    "draft a new component workflow because no relevant compatible active revision was found"
  end

  defp orchestration_required?(request) do
    request.input != %{} or request.input_paths != [] or present?(request.output_path) or
      request.required_sections != [] or objective_signal?(request.objective)
  end

  # Legacy callable workflows commonly expose only the caller-supplied
  # `input` value. Intent-authored workflows also bind source paths, artifact
  # destination, and acceptance sections, so those declarations are part of
  # the invocation contract and must participate in reuse compatibility.
  defp retrieval_input(request) do
    if request.input_paths == [] and is_nil(request.output_path) and
         request.required_sections == [] do
      request.input
    else
      request
    end
  end

  defp objective_signal?(objective) do
    objective
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> MapSet.new()
    |> MapSet.disjoint?(@workflow_terms)
    |> Kernel.not()
  end

  defp normalize_request(request) when is_list(request),
    do: request |> Map.new() |> normalize_request()

  defp normalize_request(request) when is_map(request) do
    %{
      objective: value(request, :objective),
      input: value(request, :input, %{}),
      input_paths: value(request, :input_paths, []) |> List.wrap(),
      output_path: value(request, :output_path),
      required_sections: value(request, :required_sections, []) |> List.wrap(),
      metadata: value(request, :metadata, %{})
    }
  end

  defp normalize_request(_request) do
    %{
      objective: nil,
      input: %{},
      input_paths: [],
      output_path: nil,
      required_sections: [],
      metadata: %{}
    }
  end

  defp validate_request(%{objective: objective, input: input}) do
    cond do
      not is_binary(objective) or String.trim(objective) == "" ->
        {:error,
         Error.validation("workflow intent objective must be a non-empty string",
           source: __MODULE__,
           details: %{code: :invalid_workflow_objective}
         )}

      not is_map(input) ->
        {:error,
         Error.validation("workflow intent input must be a map",
           source: __MODULE__,
           details: %{code: :invalid_workflow_input}
         )}

      true ->
        :ok
    end
  end

  defp validate_strategy(strategy) when strategy in @strategies, do: :ok

  defp validate_strategy(strategy) do
    {:error,
     Error.validation("unknown workflow intent routing strategy",
       source: __MODULE__,
       details: %{code: :invalid_routing_strategy, strategy: strategy, valid: @strategies}
     )}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp value(input, key, default \\ nil) do
    Map.get(input, key, Map.get(input, Atom.to_string(key), default))
  end
end
