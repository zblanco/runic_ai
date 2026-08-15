defmodule RunicAI.Decomposition.Evaluation do
  @moduledoc """
  Normalized reviewer or judge assessment over one candidate output.
  """

  alias RunicAI.Error

  @enforce_keys [:subject_id, :metadata]
  defstruct [:subject_id, :judge, :score, :verdict, :reason, :metadata]

  @type t :: %__MODULE__{
          subject_id: String.t(),
          judge: atom() | String.t() | nil,
          score: number() | nil,
          verdict: atom() | String.t() | nil,
          reason: String.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    subject_id = Keyword.get(opts, :subject_id)
    judge = Keyword.get(opts, :judge)
    score = Keyword.get(opts, :score)
    verdict = Keyword.get(opts, :verdict)
    reason = Keyword.get(opts, :reason)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_subject_id(subject_id),
         :ok <- validate_optional_atom_or_string(:judge, judge),
         :ok <- validate_optional_score(score),
         :ok <- validate_optional_atom_or_string(:verdict, verdict),
         :ok <- validate_optional_string(:reason, reason),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         subject_id: subject_id,
         judge: judge,
         score: score,
         verdict: verdict,
         reason: reason,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, evaluation} -> evaluation
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = evaluation) do
    new(
      subject_id: evaluation.subject_id,
      judge: evaluation.judge,
      score: evaluation.score,
      verdict: evaluation.verdict,
      reason: evaluation.reason,
      metadata: evaluation.metadata
    )
  end

  @spec from_input(t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = evaluation), do: validate(evaluation)

  def from_input(input) when is_map(input) do
    new(
      subject_id: Map.get(input, :subject_id) || Map.get(input, "subject_id"),
      judge: Map.get(input, :judge) || Map.get(input, "judge"),
      score: Map.get(input, :score) || Map.get(input, "score"),
      verdict: Map.get(input, :verdict) || Map.get(input, "verdict"),
      reason: Map.get(input, :reason) || Map.get(input, "reason"),
      metadata: Map.get(input, :metadata) || Map.get(input, "metadata") || %{}
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected an Evaluation-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | map()) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, evaluation} -> evaluation
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_subject_id(subject_id) when is_binary(subject_id) and subject_id != "", do: :ok

  defp validate_subject_id(subject_id) do
    {:error,
     Error.validation("decomposition evaluation subject_id must be a non-empty string",
       source: __MODULE__,
       details: %{subject_id: subject_id}
     )}
  end

  defp validate_optional_atom_or_string(_field, nil), do: :ok

  defp validate_optional_atom_or_string(_field, value) when is_atom(value) or is_binary(value),
    do: :ok

  defp validate_optional_atom_or_string(field, value) do
    {:error,
     Error.validation("decomposition evaluation #{field} must be an atom, string, or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_score(nil), do: :ok
  defp validate_optional_score(score) when is_integer(score) or is_float(score), do: :ok

  defp validate_optional_score(score) do
    {:error,
     Error.validation("decomposition evaluation score must be numeric or nil",
       source: __MODULE__,
       details: %{score: score}
     )}
  end

  defp validate_optional_string(_field, nil), do: :ok
  defp validate_optional_string(_field, value) when is_binary(value), do: :ok

  defp validate_optional_string(field, value) do
    {:error,
     Error.validation("decomposition evaluation #{field} must be a string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("decomposition evaluation metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
