defmodule RunicAI.RLM.Slice do
  @moduledoc """
  Provenance-preserving window over an external source.

  Offsets and lengths are expressed in characters for text sources.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.EnvironmentRef

  @enforce_keys [:id, :source_ref, :offset, :length]
  defstruct [:id, :source_ref, :offset, :length, :index, :label, provenance: [], metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          source_ref: EnvironmentRef.t(),
          offset: non_neg_integer(),
          length: non_neg_integer(),
          index: non_neg_integer() | nil,
          label: String.t() | nil,
          provenance: [term()],
          metadata: map()
        }

  @spec new(EnvironmentRef.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(%EnvironmentRef{} = source_ref, offset, length, opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id) || default_id(source_ref, offset, length)
    index = Keyword.get(opts, :index)
    label = Keyword.get(opts, :label)
    provenance = Keyword.get(opts, :provenance, [source_ref])
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, source_ref} <- EnvironmentRef.validate(source_ref),
         :ok <- validate_id(id),
         :ok <- validate_count(offset, :offset),
         :ok <- validate_count(length, :length),
         :ok <- validate_index(index),
         :ok <- validate_label(label),
         :ok <- validate_provenance(provenance),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         source_ref: source_ref,
         offset: offset,
         length: length,
         index: index,
         label: label,
         provenance: provenance,
         metadata: metadata
       }}
    end
  end

  @spec new!(EnvironmentRef.t(), non_neg_integer(), non_neg_integer(), keyword()) :: t()
  def new!(%EnvironmentRef{} = source_ref, offset, length, opts \\ []) do
    case new(source_ref, offset, length, opts) do
      {:ok, slice} -> slice
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = slice) do
    new(slice.source_ref, slice.offset, slice.length,
      id: slice.id,
      index: slice.index,
      label: slice.label,
      provenance: slice.provenance,
      metadata: slice.metadata
    )
  end

  @spec end_offset(t()) :: non_neg_integer()
  def end_offset(%__MODULE__{} = slice), do: slice.offset + slice.length

  defp default_id(%EnvironmentRef{} = source_ref, offset, length) do
    "#{source_ref.source_id}:#{offset}:#{length}"
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("slice id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_count(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp validate_count(value, field) do
    {:error,
     Error.validation("slice #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_index(nil), do: :ok
  defp validate_index(index) when is_integer(index) and index >= 0, do: :ok

  defp validate_index(index) do
    {:error,
     Error.validation("slice index must be a non-negative integer or nil",
       source: __MODULE__,
       details: %{index: index}
     )}
  end

  defp validate_label(nil), do: :ok
  defp validate_label(label) when is_binary(label), do: :ok

  defp validate_label(label) do
    {:error,
     Error.validation("slice label must be a string or nil",
       source: __MODULE__,
       details: %{label: label}
     )}
  end

  defp validate_provenance(provenance) when is_list(provenance), do: :ok

  defp validate_provenance(provenance) do
    {:error,
     Error.validation("slice provenance must be a list",
       source: __MODULE__,
       details: %{provenance: provenance}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("slice metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
