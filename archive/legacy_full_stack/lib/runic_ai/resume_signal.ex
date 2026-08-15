defmodule RunicAI.ResumeSignal do
  @moduledoc """
  Typed resume input for workflows that previously emitted a wait or review.
  """

  alias RunicAI.Error

  @enforce_keys [:kind, :resume_key, :metadata]
  defstruct [:kind, :resume_key, :payload, :metadata]

  @known_string_kinds %{
    "external_signal" => :external_signal,
    "review" => :review,
    "resume" => :resume,
    "wake" => :wake
  }

  @type t :: %__MODULE__{
          kind: atom(),
          resume_key: String.t(),
          payload: term(),
          metadata: map()
        }

  @spec new(term(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, resume_key, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    kind = normalize_kind(kind)

    with :ok <- validate_kind(kind),
         :ok <- validate_resume_key(resume_key),
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

  @spec new!(term(), term(), keyword()) :: t()
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
    new(field(input, :kind), field(input, :resume_key),
      payload: field(input, :payload),
      metadata: field(input, :metadata) || %{}
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

  defp validate_resume_key(resume_key) when is_binary(resume_key) and resume_key != "", do: :ok

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

  defp normalize_kind(kind) when is_atom(kind), do: kind
  defp normalize_kind(kind) when is_binary(kind), do: Map.get(@known_string_kinds, kind, kind)

  defp validate_kind(kind) when is_atom(kind), do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("unsupported resume signal kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, supported_string_kinds: Map.keys(@known_string_kinds)}
     )}
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
