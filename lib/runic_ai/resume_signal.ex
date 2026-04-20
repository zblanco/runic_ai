defmodule RunicAI.ResumeSignal do
  @moduledoc """
  Typed resume input for workflows that previously emitted a wait or review.
  """

  alias RunicAI.Error

  @enforce_keys [:kind, :resume_key, :metadata]
  defstruct [:kind, :resume_key, :payload, :metadata]

  @type t :: %__MODULE__{
          kind: atom(),
          resume_key: String.t(),
          payload: term(),
          metadata: map()
        }

  @spec new(atom(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, resume_key, opts \\ [])
      when is_atom(kind) and is_binary(resume_key) and is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_resume_key(resume_key),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         kind: kind,
         resume_key: resume_key,
         payload: Keyword.get(opts, :payload),
         metadata: metadata
       }}
    end
  end

  @spec new!(atom(), String.t(), keyword()) :: t()
  def new!(kind, resume_key, opts \\ []) do
    case new(kind, resume_key, opts) do
      {:ok, resume_signal} -> resume_signal
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = resume_signal) do
    new(resume_signal.kind, resume_signal.resume_key,
      payload: resume_signal.payload,
      metadata: resume_signal.metadata
    )
  end

  @spec from_input(t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = resume_signal), do: validate(resume_signal)

  def from_input(input) when is_map(input) do
    new(Map.get(input, :kind), Map.get(input, :resume_key),
      payload: Map.get(input, :payload),
      metadata: Map.get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a ResumeSignal-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | map()) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, resume_signal} -> resume_signal
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_resume_key(resume_key) when resume_key != "", do: :ok

  defp validate_resume_key(resume_key) do
    {:error,
     Error.validation("resume signal resume_key must be a non-empty string",
       source: __MODULE__,
       details: %{resume_key: resume_key}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("resume signal metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
