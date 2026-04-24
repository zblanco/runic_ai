defmodule RunicAI.Candidate.Registry do
  @moduledoc """
  In-memory candidate registry used by runtime selection policies.
  """

  alias RunicAI.Candidate.Spec
  alias RunicAI.Error

  @enforce_keys [:candidates, :metadata]
  defstruct candidates: %{}, metadata: %{}

  @type t :: %__MODULE__{candidates: %{String.t() => Spec.t()}, metadata: map()}

  @spec new([Spec.t() | keyword()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(candidates \\ [], opts \\ []) when is_list(candidates) and is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_map(metadata, :metadata) do
      Enum.reduce_while(
        candidates,
        {:ok, %__MODULE__{candidates: %{}, metadata: metadata}},
        fn candidate_input, {:ok, registry} ->
          case put(registry, candidate_input) do
            {:ok, registry} -> {:cont, {:ok, registry}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end
      )
    end
  end

  @spec new!([Spec.t() | keyword()], keyword()) :: t()
  def new!(candidates \\ [], opts \\ []) do
    case new(candidates, opts) do
      {:ok, registry} -> registry
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | [Spec.t() | keyword()]) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = registry), do: {:ok, registry}
  def from_input(candidates) when is_list(candidates), do: new(candidates)

  def from_input(other) do
    {:error,
     Error.validation("expected a Candidate.Registry-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec put(t(), Spec.t() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def put(%__MODULE__{} = registry, candidate_input) do
    with {:ok, candidate} <- Spec.from_input(candidate_input) do
      {:ok, %{registry | candidates: Map.put(registry.candidates, candidate.id, candidate)}}
    end
  end

  @spec fetch(t(), String.t()) :: {:ok, Spec.t()} | {:error, Error.t()}
  def fetch(%__MODULE__{} = registry, candidate_id) when is_binary(candidate_id) do
    case Map.fetch(registry.candidates, candidate_id) do
      {:ok, candidate} ->
        {:ok, candidate}

      :error ->
        {:error,
         Error.validation("unknown candidate id",
           source: __MODULE__,
           details: %{candidate_id: candidate_id}
         )}
    end
  end

  @spec list(t()) :: [Spec.t()]
  def list(%__MODULE__{} = registry), do: Map.values(registry.candidates)

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("candidate registry #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
