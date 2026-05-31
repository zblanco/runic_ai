defmodule RunicAI.Sandbox.GeneratedComponentCatalog.Context do
  @moduledoc """
  Coordinator-facing catalog context helpers.

  The context layer turns the storage-neutral catalog into prompt-ready
  candidate summaries and generated-component capability-gap records.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentCatalog.CapabilityGap
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Query
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Result
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Store

  @default_top_k 5

  @spec prompt_context(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def prompt_context(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    case catalog(opts) do
      nil ->
        {:ok, empty_context(objective)}

      %Store{} = store ->
        with {:ok, query} <- query_for_objective(objective, opts),
             {:ok, results} <- Store.search(store, query),
             {:ok, negative_evidence} <- Store.search_negative_evidence(store, query) do
          {:ok, context(objective, query, results, negative_evidence)}
        end

      invalid ->
        invalid_catalog(invalid)
    end
  end

  @spec prompt_context!(String.t(), keyword()) :: map()
  def prompt_context!(objective, opts \\ []) do
    case prompt_context(objective, opts) do
      {:ok, context} -> context
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec search(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, Error.t()}
  def search(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    case catalog(opts) do
      nil ->
        {:ok, []}

      %Store{} = store ->
        with {:ok, query} <- query_for_objective(objective, opts) do
          Store.search(store, query)
        end

      invalid ->
        invalid_catalog(invalid)
    end
  end

  @spec best_match(String.t(), keyword()) :: {:ok, Result.t() | nil} | {:error, Error.t()}
  def best_match(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    with {:ok, results} <- search(objective, opts) do
      {:ok, List.first(results)}
    end
  end

  @spec gap_for_proposal(String.t(), GeneratedComponent.t() | map() | keyword(), keyword()) ::
          {:ok, CapabilityGap.t()} | {:error, Error.t()}
  def gap_for_proposal(objective, proposal_input, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    with {:ok, component} <- GeneratedComponent.from_input(proposal_input),
         {:ok, query} <- query_for_component(objective, component, opts),
         {:ok, results} <- search_for_gap(opts, query) do
      CapabilityGap.new(%{
        id: Keyword.get(opts, :capability_gap_id, "gap:#{component.id}"),
        objective: objective,
        required_contract: required_contract(component, query),
        candidates: Enum.map(results, &candidate_for_gap/1),
        selected_action: Keyword.get(opts, :selected_action, :generate_leaf),
        selected_component_id: nil,
        reason: gap_reason(results),
        metadata: %{
          generated_component_id: component.id,
          catalog_query: query_summary(query),
          derived_by: __MODULE__
        }
      })
    end
  end

  @spec summarize_results([Result.t()]) :: [map()]
  def summarize_results(results) when is_list(results) do
    Enum.map(results, fn %Result{} = result ->
      %{
        id: result.entry.id,
        name: result.entry.name,
        score: result.score,
        match_reasons: result.reasons,
        promotion_target: result.entry.promotion_target,
        component_kind: result.entry.component_kind,
        language: result.entry.language,
        runtime: result.entry.runtime,
        intent_tags: result.entry.intent_tags,
        input_signature: result.entry.input_signature,
        output_signature: result.entry.output_signature,
        sandbox_profile: result.entry.sandbox_profile,
        verification: verification_summary(result.entry.verification),
        salience: result.entry.salience
      }
    end)
  end

  defp catalog(opts), do: Keyword.get(opts, :generated_component_catalog)

  defp search_for_gap(opts, query) do
    case catalog(opts) do
      nil -> {:ok, []}
      %Store{} = store -> Store.search(store, query)
      invalid -> invalid_catalog(invalid)
    end
  end

  defp query_for_objective(objective, opts) do
    case Keyword.get(opts, :generated_component_catalog_query) do
      nil ->
        Query.new(%{
          objective: objective,
          intent_tags:
            Keyword.get(
              opts,
              :generated_component_intent_tags,
              Keyword.get(opts, :intent_tags, [])
            ),
          inputs:
            Keyword.get(
              opts,
              :generated_component_inputs,
              Keyword.get(opts, :component_inputs, [])
            ),
          outputs:
            Keyword.get(
              opts,
              :generated_component_outputs,
              Keyword.get(opts, :component_outputs, [])
            ),
          component_kind: Keyword.get(opts, :generated_component_kind),
          runtime: Keyword.get(opts, :generated_component_runtime),
          policy: Keyword.get(opts, :generated_component_policy, %{}),
          top_k: Keyword.get(opts, :generated_component_catalog_top_k, @default_top_k),
          metadata: %{source: :objective_prompt_context}
        })

      query ->
        Query.new(query)
    end
  end

  defp query_for_component(objective, %GeneratedComponent{} = component, opts) do
    Query.new(%{
      objective: objective,
      intent_tags: get(component.metadata, :intent_tags, []),
      inputs: interface_ports(component, :inputs),
      outputs: interface_ports(component, :outputs),
      component_kind: :sandbox_execute,
      runtime: component.runtime,
      policy: component_policy(component),
      top_k: Keyword.get(opts, :generated_component_catalog_top_k, @default_top_k),
      metadata: %{source: :generated_component_gap}
    })
  end

  defp context(objective, %Query{} = query, results, negative_evidence) do
    candidates = summarize_results(results)

    %{
      available?: true,
      objective: objective,
      query: query_summary(query),
      candidates: candidates,
      candidate_count: length(candidates),
      negative_evidence: summarize_negative_evidence(negative_evidence),
      negative_evidence_count: length(negative_evidence),
      instructions: [
        "Prefer an exact catalog candidate when its contract and policy match the objective.",
        "Generate a new sandbox component only for a narrow testable gap.",
        "If generating, preserve candidate ids and rejection reasons in a capability gap decision."
      ]
    }
  end

  defp empty_context(objective) do
    %{
      available?: false,
      objective: objective,
      query: %{},
      candidates: [],
      candidate_count: 0,
      negative_evidence: [],
      negative_evidence_count: 0,
      instructions: []
    }
  end

  defp summarize_negative_evidence(evidence) when is_list(evidence) do
    Enum.map(evidence, fn evidence ->
      %{
        id: evidence.id,
        component_id: evidence.component_id,
        objective: evidence.objective,
        required_contract: evidence.required_contract,
        proof_id: evidence.proof_id,
        command: evidence.command,
        diagnostics: evidence.diagnostics,
        reason: evidence.reason,
        occurred_at: evidence.occurred_at
      }
    end)
  end

  defp required_contract(%GeneratedComponent{} = component, %Query{} = query) do
    %{
      component_id: component.id,
      name: component.name,
      language: component.language,
      runtime: component.runtime,
      entrypoint: component.entrypoint,
      inputs: query.inputs,
      outputs: query.outputs,
      intent_tags: query.intent_tags,
      policy: query.policy
    }
  end

  defp candidate_for_gap(%Result{} = result) do
    result
    |> CapabilityGap.candidate_from_result()
    |> Map.put(:rejection_reason, "not selected for generated component proposal")
  end

  defp gap_reason([]),
    do: "No catalog candidate matched the required generated component contract."

  defp gap_reason(_results) do
    "Generated component proposal requested after considering catalog candidates; proof flow preserves candidates for review."
  end

  defp query_summary(%Query{} = query) do
    %{
      objective: query.objective,
      intent_tags: query.intent_tags,
      inputs: query.inputs,
      outputs: query.outputs,
      component_kind: query.component_kind,
      runtime: query.runtime,
      policy: query.policy,
      top_k: query.top_k
    }
  end

  defp verification_summary(verification) when is_map(verification) do
    %{
      status: get(verification, :status),
      proof_ref: get(verification, :proof_ref),
      command: get(verification, :command)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp verification_summary(_verification), do: %{}

  defp interface_ports(%GeneratedComponent{interface: interface}, key) when is_map(interface) do
    case get(interface, key, []) do
      ports when is_list(ports) -> ports
      _other -> []
    end
  end

  defp component_policy(%GeneratedComponent{metadata: metadata}) when is_map(metadata) do
    metadata
    |> get(:policy, %{})
    |> case do
      policy when is_map(policy) ->
        network = get(policy, :network, get(metadata, :network, :disabled))
        Map.put(policy, :network, network)

      _other ->
        %{network: get(metadata, :network, :disabled)}
    end
  end

  defp invalid_catalog(invalid) do
    {:error,
     Error.validation("generated component catalog context requires a catalog store",
       source: __MODULE__,
       details: %{catalog: invalid}
     )}
  end

  defp get(map, key, default \\ nil)
  defp get(nil, _key, default), do: default

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_other, _key, default), do: default
end
