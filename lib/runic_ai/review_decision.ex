defmodule RunicAI.ReviewDecision do
  @moduledoc """
  Typed operator decision for a review request.
  """

  alias RunicAI.Error

  @valid_statuses [:approved, :rejected, :edited, :cancelled]

  @enforce_keys [:resume_key, :status, :metadata]
  defstruct [:resume_key, :status, :edited_value, :actor, :metadata]

  @type status :: :approved | :rejected | :edited | :cancelled

  @type t :: %__MODULE__{
          resume_key: String.t(),
          status: status(),
          edited_value: term(),
          actor: term(),
          metadata: map()
        }

  @spec new(String.t(), status(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(resume_key, status, opts \\ [])
      when is_binary(resume_key) and is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_resume_key(resume_key),
         :ok <- validate_status(status),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         resume_key: resume_key,
         status: status,
         edited_value: Keyword.get(opts, :edited_value),
         actor: Keyword.get(opts, :actor),
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t(), status(), keyword()) :: t()
  def new!(resume_key, status, opts \\ []) do
    case new(resume_key, status, opts) do
      {:ok, review_decision} -> review_decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = review_decision) do
    new(review_decision.resume_key, review_decision.status,
      edited_value: review_decision.edited_value,
      actor: review_decision.actor,
      metadata: review_decision.metadata
    )
  end

  @spec from_input(t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = review_decision), do: validate(review_decision)

  def from_input(input) when is_map(input) do
    new(Map.get(input, :resume_key), Map.get(input, :status),
      edited_value: Map.get(input, :edited_value),
      actor: Map.get(input, :actor),
      metadata: Map.get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a ReviewDecision-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | map()) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, review_decision} -> review_decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_resume_key(resume_key) when resume_key != "", do: :ok

  defp validate_resume_key(resume_key) do
    {:error,
     Error.validation("review decision resume_key must be a non-empty string",
       source: __MODULE__,
       details: %{resume_key: resume_key}
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid review decision status: #{inspect(status)}",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("review decision metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
