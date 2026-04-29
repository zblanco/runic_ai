defmodule RunicAI.Coding.RLM.Artifact do
  @moduledoc """
  Generic coding artifact emitted by RLM coding nodes and reducers.
  """

  alias RunicAI.Error

  @valid_kinds [
    :finding,
    :contract_fact,
    :risk,
    :patch_plan,
    :verification_observation,
    :repair_need,
    :episode,
    :codex_event,
    :report
  ]

  @enforce_keys [:id, :kind, :content, :provenance, :metadata]
  defstruct [:id, :kind, :content, provenance: [], metadata: %{}]

  @type kind ::
          :finding
          | :contract_fact
          | :risk
          | :patch_plan
          | :verification_observation
          | :repair_need
          | :episode
          | :codex_event
          | :report

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          content: term(),
          provenance: [term()],
          metadata: map()
        }

  @spec new(kind() | String.t(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, content, opts \\ []) when is_list(opts) do
    artifact = %__MODULE__{
      id: Keyword.get(opts, :id) || "coding-rlm-artifact:#{System.unique_integer([:positive])}",
      kind: normalize_kind(kind),
      content: content,
      provenance: Keyword.get(opts, :provenance, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(artifact)
  end

  @spec new!(kind() | String.t(), term(), keyword()) :: t()
  def new!(kind, content, opts \\ []) do
    case new(kind, content, opts) do
      {:ok, artifact} -> artifact
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = artifact) do
    with :ok <- validate_id(artifact.id),
         :ok <- validate_kind(artifact.kind),
         :ok <- validate_list(artifact.provenance, :provenance),
         :ok <- validate_map(artifact.metadata, :metadata) do
      {:ok, artifact}
    end
  end

  defp normalize_kind(kind) when kind in @valid_kinds, do: kind
  defp normalize_kind(kind) when is_binary(kind), do: lookup_kind(kind)
  defp normalize_kind(kind), do: kind

  defp lookup_kind("finding"), do: :finding
  defp lookup_kind("contract_fact"), do: :contract_fact
  defp lookup_kind("risk"), do: :risk
  defp lookup_kind("patch_plan"), do: :patch_plan
  defp lookup_kind("verification_observation"), do: :verification_observation
  defp lookup_kind("repair_need"), do: :repair_need
  defp lookup_kind("episode"), do: :episode
  defp lookup_kind("codex_event"), do: :codex_event
  defp lookup_kind("report"), do: :report
  defp lookup_kind(kind), do: kind

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("artifact id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid coding RLM artifact kind",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("artifact #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("artifact #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
