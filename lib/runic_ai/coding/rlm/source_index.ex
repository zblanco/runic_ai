defmodule RunicAI.Coding.RLM.SourceIndex do
  @moduledoc """
  Index of codebase source refs registered for an RLM coding run.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.EnvironmentRef

  defstruct refs_by_id: %{}, refs_by_path: %{}, metadata: %{}

  @type entry :: %{
          required(:id) => String.t(),
          required(:ref) => EnvironmentRef.t(),
          required(:kind) => atom(),
          required(:metadata) => map()
        }

  @type t :: %__MODULE__{
          refs_by_id: %{String.t() => entry()},
          refs_by_path: %{String.t() => String.t()},
          metadata: map()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: %__MODULE__{metadata: Keyword.get(opts, :metadata, %{})}

  @spec put(t(), EnvironmentRef.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def put(%__MODULE__{} = index, %EnvironmentRef{} = ref, opts \\ []) do
    id = Keyword.get(opts, :id, ref.source_id)
    path = Keyword.get(opts, :path)
    kind = Keyword.get(opts, :kind, :source)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_optional_path(path),
         :ok <- validate_metadata(metadata) do
      entry = %{id: id, ref: ref, path: path, kind: kind, metadata: metadata}

      refs_by_path =
        case path do
          nil -> index.refs_by_path
          path -> Map.put(index.refs_by_path, path, id)
        end

      {:ok,
       %{index | refs_by_id: Map.put(index.refs_by_id, id, entry), refs_by_path: refs_by_path}}
    end
  end

  @spec fetch(t(), String.t()) :: {:ok, entry()} | {:error, Error.t()}
  def fetch(%__MODULE__{} = index, id_or_path) when is_binary(id_or_path) do
    id = Map.get(index.refs_by_path, id_or_path, id_or_path)

    case Map.fetch(index.refs_by_id, id) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        {:error,
         Error.validation("source index entry not found",
           source: __MODULE__,
           details: %{id_or_path: id_or_path}
         )}
    end
  end

  @spec list(t()) :: [entry()]
  def list(%__MODULE__{} = index), do: Map.values(index.refs_by_id)

  @spec summaries(t(), non_neg_integer()) :: [map()]
  def summaries(%__MODULE__{} = index, limit \\ 100) do
    index
    |> list()
    |> Enum.sort_by(& &1.id)
    |> Enum.take(limit)
    |> Enum.map(fn entry ->
      entry
      |> Map.take([:id, :path, :kind])
      |> Map.put(:ref, entry.ref.source_id)
      |> Map.put(:metadata, Map.take(entry.metadata, [:language, :size, :checksum, :tags]))
    end)
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("source index id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_optional_path(nil), do: :ok
  defp validate_optional_path(path) when is_binary(path), do: :ok

  defp validate_optional_path(path) do
    {:error,
     Error.validation("source index path must be a string or nil",
       source: __MODULE__,
       details: %{path: path}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("source index metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
