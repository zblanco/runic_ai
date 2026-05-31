defmodule RunicAI.Sandbox.GeneratedComponentCatalog.NegativeEvidence do
  @moduledoc """
  Catalog record for failed generated-component proof attempts.

  Negative evidence is not reusable as a component. It preserves enough
  contract, candidate, proof, and diagnostic context for later gap decisions and
  repair loops to avoid repeating failed generated shapes.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponentCatalog.CapabilityGap

  @enforce_keys [
    :id,
    :component_id,
    :objective,
    :required_contract,
    :candidates,
    :proof_id,
    :command,
    :diagnostics,
    :source_artifacts,
    :test_artifacts,
    :reason,
    :metadata
  ]
  @derive Jason.Encoder
  defstruct [
    :id,
    :component_id,
    :objective,
    :required_contract,
    :candidates,
    :proof_id,
    :command,
    :diagnostics,
    :source_artifacts,
    :test_artifacts,
    :reason,
    :occurred_at,
    :metadata
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          component_id: String.t(),
          objective: String.t(),
          required_contract: map(),
          candidates: [map()],
          proof_id: String.t(),
          command: String.t(),
          diagnostics: map(),
          source_artifacts: [map()],
          test_artifacts: [map()],
          reason: atom() | String.t(),
          occurred_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(input) when is_list(input) or is_map(input) do
    input = input_map(input)

    with :ok <- validate_non_empty_string(get(input, :id, default_id(input)), :id),
         :ok <- validate_non_empty_string(get(input, :component_id), :component_id),
         :ok <- validate_non_empty_string(get(input, :objective), :objective),
         {:ok, required_contract} <-
           normalize_map(get(input, :required_contract, %{}), :required_contract),
         {:ok, candidates} <- normalize_list(get(input, :candidates, []), :candidates),
         :ok <- validate_non_empty_string(get(input, :proof_id), :proof_id),
         :ok <- validate_non_empty_string(get(input, :command), :command),
         {:ok, diagnostics} <- normalize_map(get(input, :diagnostics, %{}), :diagnostics),
         {:ok, source_artifacts} <-
           normalize_list(get(input, :source_artifacts, []), :source_artifacts),
         {:ok, test_artifacts} <- normalize_list(get(input, :test_artifacts, []), :test_artifacts),
         :ok <- validate_reason(get(input, :reason)),
         :ok <- validate_optional_datetime(get(input, :occurred_at)),
         {:ok, metadata} <- normalize_map(get(input, :metadata, %{}), :metadata) do
      {:ok,
       %__MODULE__{
         id: get(input, :id, default_id(input)),
         component_id: get(input, :component_id),
         objective: get(input, :objective),
         required_contract: required_contract,
         candidates: candidates,
         proof_id: get(input, :proof_id),
         command: get(input, :command),
         diagnostics: diagnostics,
         source_artifacts: source_artifacts,
         test_artifacts: test_artifacts,
         reason: get(input, :reason),
         occurred_at: get(input, :occurred_at),
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, evidence} -> evidence
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = evidence) do
    new(%{
      id: evidence.id,
      component_id: evidence.component_id,
      objective: evidence.objective,
      required_contract: evidence.required_contract,
      candidates: evidence.candidates,
      proof_id: evidence.proof_id,
      command: evidence.command,
      diagnostics: evidence.diagnostics,
      source_artifacts: evidence.source_artifacts,
      test_artifacts: evidence.test_artifacts,
      reason: evidence.reason,
      occurred_at: evidence.occurred_at,
      metadata: evidence.metadata
    })
  end

  @spec from_failed_proof(map(), CapabilityGap.t() | map(), map(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def from_failed_proof(proof, capability_gap, decision, opts \\ [])
      when is_map(proof) and is_list(opts) do
    with {:ok, gap} <- normalize_gap(capability_gap) do
      component = Map.fetch!(proof, :component)

      new(%{
        id: Keyword.get(opts, :id, "negative:#{proof.id}"),
        component_id: component.id,
        objective: gap.objective,
        required_contract: gap.required_contract,
        candidates: gap.candidates,
        proof_id: proof.id,
        command: proof.command,
        diagnostics: component.verification.diagnostics || %{},
        source_artifacts: proof.source_artifacts,
        test_artifacts: proof.test_artifacts,
        reason: decision_reason(decision),
        occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now()),
        metadata: %{
          capability_gap_id: gap.id,
          selected_action: gap.selected_action,
          promotion_decision: decision_summary(decision)
        }
      })
    end
  end

  defp normalize_gap(%CapabilityGap{} = gap), do: CapabilityGap.validate(gap)
  defp normalize_gap(gap) when is_map(gap) or is_list(gap), do: CapabilityGap.new(gap)

  defp decision_reason(decision) when is_map(decision),
    do: get(decision, :reason, :proof_failed)

  defp decision_reason(_decision), do: :proof_failed

  defp decision_summary(decision) when is_map(decision) do
    %{
      action: get(decision, :action),
      reason: get(decision, :reason),
      details: get(decision, :details, %{})
    }
  end

  defp decision_summary(decision), do: %{value: decision}

  defp validate_reason(reason) when is_atom(reason), do: :ok
  defp validate_reason(reason) when is_binary(reason) and reason != "", do: :ok

  defp validate_reason(reason) do
    {:error,
     Error.validation("generated component negative evidence reason must be an atom or string",
       source: __MODULE__,
       details: %{reason: reason}
     )}
  end

  defp validate_non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_non_empty_string(value, field) do
    {:error,
     Error.validation("generated component negative evidence #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_map(value, _field) when is_map(value), do: {:ok, value}

  defp normalize_map(value, field) do
    {:error,
     Error.validation("generated component negative evidence #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_list(value, _field) when is_list(value), do: {:ok, value}

  defp normalize_list(value, field) do
    {:error,
     Error.validation("generated component negative evidence #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_datetime(nil), do: :ok
  defp validate_optional_datetime(%DateTime{}), do: :ok

  defp validate_optional_datetime(value) do
    {:error,
     Error.validation(
       "generated component negative evidence occurred_at must be a DateTime or nil",
       source: __MODULE__,
       details: %{occurred_at: value}
     )}
  end

  defp default_id(input) do
    proof_id = get(input, :proof_id, "proof")
    "negative:#{proof_id}"
  end

  defp input_map(input) when is_map(input), do: input
  defp input_map(input) when is_list(input), do: Map.new(input)

  defp get(map, key, default \\ nil)
  defp get(nil, _key, default), do: default

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_other, _key, default), do: default
end
