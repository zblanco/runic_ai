defmodule RunicAI.Persistence.WorkflowLibrary do
  @moduledoc """
  Retrieval and exact resolution for activated, reusable workflow revisions.
  """

  alias RunicAI.Error
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Persistence.Schemas.ManagedWorkflow
  alias RunicAI.Persistence.Schemas.WorkflowDefinitionRevision
  alias RunicAI.Workflows.PublicContract

  @intent_risk_terms MapSet.new(~w[
                       delete deploy disable drop erase never not overwrite publish purge remove
                       revoke send stop truncate
                     ])
  @objective_stop_terms MapSet.new(~w[a an supplied the])

  @type resolved :: %{
          required(:workflow) => ManagedWorkflow.t(),
          required(:revision) => WorkflowDefinitionRevision.t(),
          required(:contract) => PublicContract.t(),
          required(:reference) => map()
        }

  @spec resolve(Store.t(), String.t() | map()) :: {:ok, resolved()} | {:error, term()}
  def resolve(%Store{} = store, reference) when is_binary(reference) do
    case String.split(reference, "@", parts: 2) do
      [workflow_key, revision] ->
        case Integer.parse(revision) do
          {number, ""} -> resolve(store, %{workflow_key: workflow_key, revision: number})
          _other -> {:error, invalid_reference(reference)}
        end

      [workflow_key] ->
        resolve(store, %{workflow_key: workflow_key})
    end
  end

  def resolve(%Store{} = store, reference) when is_map(reference) do
    workflow_key = value(reference, :workflow_key, value(reference, :key, nil))

    with true <-
           (is_binary(workflow_key) and workflow_key != "") ||
             {:error, invalid_reference(reference)},
         %ManagedWorkflow{} = workflow <- WorkflowDefinitions.get(store, workflow_key),
         true <- workflow.status == "active" || {:error, :workflow_not_active},
         %WorkflowDefinitionRevision{} = revision <-
           WorkflowDefinitions.get_revision(store, workflow.active_revision_id),
         :ok <- match_reference(reference, workflow, revision),
         {:ok, contract} <- PublicContract.from_revision(workflow, revision) do
      {:ok,
       %{
         workflow: workflow,
         revision: revision,
         contract: contract,
         reference: %{
           workflow_key: workflow.workflow_key,
           revision_id: revision.id,
           revision: revision.revision,
           definition_hash: revision.semantic_hash,
           contract_hash: contract.contract_hash
         }
       }}
    else
      nil -> {:error, :not_found}
      false -> {:error, invalid_reference(reference)}
      {:error, _reason} = error -> error
    end
  end

  def resolve(%Store{}, reference), do: {:error, invalid_reference(reference)}

  @spec retrieve(Store.t(), String.t(), term(), keyword()) :: map()
  def retrieve(%Store{} = store, objective, input, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 5)
    exact_similarity = Keyword.get(opts, :exact_similarity, 0.75)
    adapt_similarity = Keyword.get(opts, :adapt_similarity, 0.2)
    objective_terms = terms(objective)

    candidates =
      store
      |> Queries.active_managed_workflows()
      |> Enum.flat_map(fn workflow ->
        case resolve(store, %{workflow_key: workflow.workflow_key}) do
          {:ok, resolved} ->
            contract_match = validate_retrieval_input(resolved.contract, input)
            adaptation_match = validate_adaptation_input(resolved.contract, input)
            candidate_objective = revision_objective(resolved)
            overlap = overlap_score(objective_terms, resolved, candidate_objective)
            exact_objective? = same_objective?(objective, candidate_objective)
            intent_compatible? = intent_compatible?(objective, candidate_objective)

            score =
              overlap +
                cond do
                  contract_match == :ok and exact_objective? -> 1.0
                  adaptation_match == :ok and intent_compatible? -> 0.5
                  true -> -1.0
                end

            [
              Map.merge(resolved, %{
                score: score,
                candidate_objective: candidate_objective,
                objective_similarity: overlap,
                exact_objective?: exact_objective?,
                intent_compatible?: intent_compatible?,
                exact_reuse?: contract_match == :ok and exact_objective?,
                compatible?: contract_match == :ok,
                compatibility: contract_match,
                adaptable?: adaptation_match == :ok and intent_compatible?,
                adaptation_compatibility: adaptation_match,
                reasons:
                  candidate_reasons(
                    overlap,
                    contract_match,
                    adaptation_match,
                    exact_objective?,
                    intent_compatible?
                  )
              })
            ]

          {:error, _reason} ->
            []
        end
      end)
      |> Enum.sort_by(&{-&1.score, &1.workflow.workflow_key})
      |> Enum.take(limit)

    invokable = Enum.filter(candidates, & &1.exact_reuse?)
    adaptable = Enum.filter(candidates, & &1.adaptable?)

    {decision, selected} =
      cond do
        selected = Enum.find(invokable, &(&1.objective_similarity >= exact_similarity)) ->
          {:reuse_exact, selected}

        selected = Enum.find(adaptable, &(&1.objective_similarity >= adapt_similarity)) ->
          {:adapt, selected}

        true ->
          {:miss, nil}
      end

    %{
      objective: objective,
      decision: decision,
      selected: selected,
      candidates: candidates,
      thresholds: %{exact_similarity: exact_similarity, adapt_similarity: adapt_similarity},
      rationale: retrieval_rationale(decision)
    }
  end

  defp retrieval_rationale(:reuse_exact) do
    "selected an activated workflow with a compatible public input contract and strong objective match"
  end

  defp retrieval_rationale(:adapt) do
    "selected a compatible activated workflow as an adaptation starting point"
  end

  defp retrieval_rationale(:miss) do
    "no activated workflow was both input-compatible and relevant enough to select"
  end

  defp validate_retrieval_input(%PublicContract{inputs: inputs} = contract, input)
       when inputs not in [%{}, nil] do
    PublicContract.validate_input(contract, input)
  end

  defp validate_retrieval_input(%PublicContract{} = contract, _input) do
    {:error,
     Error.validation("saved workflow has no declared public input contract",
       source: __MODULE__,
       details: %{
         code: :workflow_public_input_contract_undeclared,
         workflow_key: contract.workflow_key,
         revision_id: contract.revision_id
       }
     )}
  end

  defp validate_adaptation_input(%PublicContract{inputs: inputs} = contract, input)
       when inputs not in [%{}, nil] do
    PublicContract.validate_adaptation_input(contract, input)
  end

  defp validate_adaptation_input(%PublicContract{} = contract, _input) do
    {:error,
     Error.validation("saved workflow has no declared public adaptation input contract",
       source: __MODULE__,
       details: %{
         code: :workflow_public_adaptation_input_contract_undeclared,
         workflow_key: contract.workflow_key,
         revision_id: contract.revision_id
       }
     )}
  end

  defp match_reference(reference, workflow, revision) do
    checks = [
      {:revision_id, revision.id},
      {:revision, revision.revision},
      {:definition_hash, revision.semantic_hash},
      {:contract_hash, revision.contract_hash}
    ]

    Enum.reduce_while(checks, :ok, fn {key, actual}, :ok ->
      case value(reference, key, nil) do
        nil ->
          {:cont, :ok}

        ^actual ->
          {:cont, :ok}

        expected ->
          {:halt,
           {:error,
            Error.validation("saved workflow reference does not match the active revision",
              source: __MODULE__,
              details: %{
                code: :workflow_reference_mismatch,
                workflow_key: workflow.workflow_key,
                field: key,
                expected: expected,
                actual: actual
              }
            )}}
      end
    end)
  end

  defp overlap_score(objective_terms, resolved, candidate_objective) do
    candidate_terms =
      terms(
        "#{candidate_objective} #{resolved.workflow.workflow_key} #{resolved.workflow.workflow_name}"
      )

    case MapSet.size(objective_terms) do
      0 ->
        0.0

      count ->
        MapSet.intersection(objective_terms, candidate_terms) |> MapSet.size() |> Kernel./(count)
    end
  end

  defp candidate_reasons(
         overlap,
         invocation_match,
         adaptation_match,
         exact_objective?,
         intent_compatible?
       ) do
    [
      match_reason(:invocation, invocation_match),
      match_reason(:adaptation, adaptation_match),
      if(exact_objective?, do: :same_normalized_objective, else: :objective_requires_adaptation),
      if(intent_compatible?, do: :intent_risk_compatible, else: :intent_risk_mismatch),
      {:term_overlap, overlap}
    ]
  end

  defp revision_objective(%{revision: %{ir_json: ir_json}}) when is_map(ir_json) do
    value(ir_json, :objective, "") |> to_string()
  end

  defp revision_objective(_resolved), do: ""

  defp same_objective?(left, right), do: normalize_objective(left) == normalize_objective(right)

  defp intent_compatible?(requested, candidate) do
    requested_risks = requested |> terms() |> MapSet.intersection(@intent_risk_terms)
    candidate_risks = candidate |> terms() |> MapSet.intersection(@intent_risk_terms)
    MapSet.equal?(requested_risks, candidate_risks)
  end

  defp normalize_objective(objective) do
    objective
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reject(&MapSet.member?(@objective_stop_terms, &1))
    |> Enum.join(" ")
  end

  defp match_reason(:invocation, :ok), do: :input_contract_compatible

  defp match_reason(:invocation, {:error, error}),
    do: {:input_contract_rejected, error.details}

  defp match_reason(:adaptation, :ok), do: :adaptation_input_contract_compatible

  defp match_reason(:adaptation, {:error, error}),
    do: {:adaptation_input_contract_rejected, error.details}

  defp terms(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp invalid_reference(reference) do
    Error.validation("saved workflow reference is invalid",
      source: __MODULE__,
      details: %{code: :invalid_workflow_reference, reference: reference}
    )
  end

  defp value(input, key, default) do
    Map.get(input, key, Map.get(input, Atom.to_string(key), default))
  end
end
