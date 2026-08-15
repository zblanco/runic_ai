defmodule RunicAI.RLM.Source do
  @moduledoc """
  Metadata for a source stored outside the root model context.
  """

  alias RunicAI.Error

  @valid_kinds [:text, :document, :code, :structured, :artifact]

  @enforce_keys [:id, :kind, :size]
  defstruct [:id, :kind, :label, :size, :checksum, metadata: %{}]

  @type kind :: :text | :document | :code | :structured | :artifact

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          label: String.t() | nil,
          size: non_neg_integer(),
          checksum: String.t() | nil,
          metadata: map()
        }

  @spec new(String.t() | integer(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, opts \\ []) when is_list(opts) do
    id = normalize_id(id)
    kind = Keyword.get(opts, :kind, :text)
    label = Keyword.get(opts, :label)
    size = Keyword.get(opts, :size, 0)
    checksum = Keyword.get(opts, :checksum)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_kind(kind),
         :ok <- validate_label(label),
         :ok <- validate_size(size),
         :ok <- validate_checksum(checksum),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         label: label,
         size: size,
         checksum: checksum,
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t() | integer(), keyword()) :: t()
  def new!(id, opts \\ []) do
    case new(id, opts) do
      {:ok, source} -> source
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = source) do
    new(source.id,
      kind: source.kind,
      label: source.label,
      size: source.size,
      checksum: source.checksum,
      metadata: source.metadata
    )
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = source), do: validate(source)

  def from_input(input) when is_map(input) do
    new(map_get(input, :id),
      kind: map_get(input, :kind) || :text,
      label: map_get(input, :label),
      size: map_get(input, :size) || 0,
      checksum: map_get(input, :checksum),
      metadata: map_get(input, :metadata) || %{}
    )
  end

  def from_input(input) when is_list(input), do: input |> Map.new() |> from_input()

  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id), do: to_string(id)

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("source id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid source kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_label(nil), do: :ok
  defp validate_label(label) when is_binary(label), do: :ok

  defp validate_label(label) do
    {:error,
     Error.validation("source label must be a string or nil",
       source: __MODULE__,
       details: %{label: label}
     )}
  end

  defp validate_size(size) when is_integer(size) and size >= 0, do: :ok

  defp validate_size(size) do
    {:error,
     Error.validation("source size must be a non-negative integer",
       source: __MODULE__,
       details: %{size: size}
     )}
  end

  defp validate_checksum(nil), do: :ok
  defp validate_checksum(checksum) when is_binary(checksum), do: :ok

  defp validate_checksum(checksum) do
    {:error,
     Error.validation("source checksum must be a string or nil",
       source: __MODULE__,
       details: %{checksum: checksum}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("source metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
