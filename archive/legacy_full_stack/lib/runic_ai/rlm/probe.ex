defmodule RunicAI.RLM.Probe do
  @moduledoc """
  Lightweight source measurement used by planners and cost models.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.EnvironmentRef

  @enforce_keys [:source_ref, :size]
  defstruct [:source_ref, :size, metadata: %{}]

  @type t :: %__MODULE__{
          source_ref: EnvironmentRef.t(),
          size: non_neg_integer(),
          metadata: map()
        }

  @spec new(EnvironmentRef.t(), non_neg_integer(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%EnvironmentRef{} = source_ref, size, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, source_ref} <- EnvironmentRef.validate(source_ref),
         :ok <- validate_size(size),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{source_ref: source_ref, size: size, metadata: metadata}}
    end
  end

  @spec new!(EnvironmentRef.t(), non_neg_integer(), keyword()) :: t()
  def new!(%EnvironmentRef{} = source_ref, size, opts \\ []) do
    case new(source_ref, size, opts) do
      {:ok, probe} -> probe
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = probe) do
    new(probe.source_ref, probe.size, metadata: probe.metadata)
  end

  defp validate_size(size) when is_integer(size) and size >= 0, do: :ok

  defp validate_size(size) do
    {:error,
     Error.validation("probe size must be a non-negative integer",
       source: __MODULE__,
       details: %{size: size}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("probe metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
