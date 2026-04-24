defmodule RunicAI.Candidate.Assignment do
  @moduledoc """
  Stable candidate assignment selected at runtime session start.
  """

  alias RunicAI.Candidate.Spec
  alias RunicAI.Error

  @enforce_keys [:candidate_id, :candidate, :reason, :metadata]
  defstruct [:candidate_id, :candidate, :reason, metadata: %{}]

  @type t :: %__MODULE__{
          candidate_id: String.t(),
          candidate: Spec.t(),
          reason: atom(),
          metadata: map()
        }

  @spec new(String.t(), Spec.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(candidate_id, %Spec{} = candidate, opts \\ []) do
    reason = Keyword.get(opts, :reason, :selected)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, candidate} <- Spec.validate(candidate),
         :ok <- validate_candidate_id(candidate_id),
         :ok <- validate_reason(reason),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         candidate_id: candidate_id,
         candidate: candidate,
         reason: reason,
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t(), Spec.t(), keyword()) :: t()
  def new!(candidate_id, %Spec{} = candidate, opts \\ []) do
    case new(candidate_id, candidate, opts) do
      {:ok, assignment} -> assignment
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_candidate_id(candidate_id) when is_binary(candidate_id) and candidate_id != "",
    do: :ok

  defp validate_candidate_id(candidate_id) do
    {:error,
     Error.validation("candidate assignment id must be a non-empty string",
       source: __MODULE__,
       details: %{candidate_id: candidate_id}
     )}
  end

  defp validate_reason(reason) when is_atom(reason), do: :ok

  defp validate_reason(reason) do
    {:error,
     Error.validation("candidate assignment reason must be an atom",
       source: __MODULE__,
       details: %{reason: reason}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("candidate assignment #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
