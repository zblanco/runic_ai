defmodule RunicAI.RLM.Environments.InMemory do
  @moduledoc """
  In-memory RLM environment for tests, examples, and small local workflows.
  """

  @behaviour RunicAI.RLM.Environment

  alias RunicAI.Error
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.MaterializedArtifact
  alias RunicAI.RLM.Slice
  alias RunicAI.RLM.SliceSet
  alias RunicAI.RLM.Source

  defstruct sources: %{}, metadata: %{}

  @type t :: %__MODULE__{
          sources: %{String.t() => %{source: Source.t(), content: String.t()}},
          metadata: map()
        }

  @impl true
  def init(opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    if is_map(metadata) do
      {:ok, %__MODULE__{metadata: metadata}}
    else
      {:error,
       Error.validation("in-memory environment metadata must be a map", source: __MODULE__)}
    end
  end

  @impl true
  def put_source(%__MODULE__{} = environment, content, opts \\ [])
      when is_binary(content) and is_list(opts) do
    id = Keyword.get(opts, :id) || next_id(environment)
    label = Keyword.get(opts, :label)
    kind = Keyword.get(opts, :kind, :text)
    metadata = Keyword.get(opts, :metadata, %{})
    checksum = checksum(content)

    with {:ok, source} <-
           Source.new(id,
             kind: kind,
             label: label,
             size: String.length(content),
             checksum: checksum,
             metadata: metadata
           ),
         {:ok, ref} <-
           EnvironmentRef.new(__MODULE__, id,
             label: label,
             metadata: Map.merge(metadata, %{checksum: checksum, size: source.size})
           ) do
      environment = put_in(environment.sources[source.id], %{source: source, content: content})
      {:ok, ref, environment}
    end
  end

  @impl true
  def get_source(%__MODULE__{} = environment, %EnvironmentRef{} = ref) do
    with {:ok, entry} <- fetch_entry(environment, ref) do
      {:ok, entry.source}
    end
  end

  @impl true
  def metadata(%__MODULE__{} = environment, %EnvironmentRef{} = ref) do
    with {:ok, source} <- get_source(environment, ref) do
      {:ok, source.metadata}
    end
  end

  @impl true
  def size(%__MODULE__{} = environment, %EnvironmentRef{} = ref) do
    with {:ok, source} <- get_source(environment, ref) do
      {:ok, source.size}
    end
  end

  @impl true
  def peek(%__MODULE__{} = environment, %EnvironmentRef{} = ref, offset, length)
      when is_integer(offset) and is_integer(length) do
    with {:ok, slice} <- slice(environment, ref, offset, length, []),
         {:ok, artifact} <- materialize(environment, slice, []) do
      {:ok, artifact}
    end
  end

  @impl true
  def slice(%__MODULE__{} = environment, %EnvironmentRef{} = ref, offset, length, opts \\ [])
      when is_integer(offset) and is_integer(length) and is_list(opts) do
    with {:ok, entry} <- fetch_entry(environment, ref),
         :ok <- ensure_bounds(entry.source, offset, length) do
      Slice.new(ref, offset, length,
        id: Keyword.get(opts, :id),
        index: Keyword.get(opts, :index),
        label: Keyword.get(opts, :label),
        metadata: Keyword.get(opts, :metadata, %{})
      )
    end
  end

  @impl true
  def split(%__MODULE__{} = environment, %EnvironmentRef{} = ref, opts \\ [])
      when is_list(opts) do
    chunk_size = Keyword.get(opts, :chunk_size, 4_000)
    overlap = Keyword.get(opts, :overlap, 0)

    with :ok <- validate_chunking(chunk_size, overlap),
         {:ok, entry} <- fetch_entry(environment, ref) do
      slices =
        entry.source.size
        |> offsets(chunk_size, overlap)
        |> Enum.with_index()
        |> Enum.map(fn {offset, index} ->
          length = min(chunk_size, entry.source.size - offset)

          Slice.new!(ref, offset, length,
            index: index,
            label: "#{ref.source_id}:#{index}",
            metadata: %{split: :characters, chunk_size: chunk_size, overlap: overlap}
          )
        end)

      SliceSet.new(slices,
        source_ref: ref,
        metadata: %{split: :characters, chunk_size: chunk_size, overlap: overlap}
      )
    end
  end

  @impl true
  def search(%__MODULE__{} = environment, %EnvironmentRef{} = ref, query, opts \\ [])
      when is_binary(query) and is_list(opts) do
    context = Keyword.get(opts, :context, 0)

    with :ok <- validate_search(query, context),
         {:ok, entry} <- fetch_entry(environment, ref) do
      query_length = String.length(query)

      slices =
        entry.content
        |> match_offsets(query)
        |> Enum.with_index()
        |> Enum.map(fn {match_offset, index} ->
          offset = max(match_offset - context, 0)
          end_offset = min(match_offset + query_length + context, entry.source.size)

          Slice.new!(ref, offset, end_offset - offset,
            index: index,
            label: "#{ref.source_id}:match:#{index}",
            metadata: %{query: query, match_offset: match_offset}
          )
        end)

      SliceSet.new(slices, source_ref: ref, metadata: %{query: query, context: context})
    end
  end

  @impl true
  def materialize(%__MODULE__{} = environment, %EnvironmentRef{} = ref, opts) do
    with {:ok, entry} <- fetch_entry(environment, ref) do
      MaterializedArtifact.new(entry.content,
        id: Keyword.get(opts, :id) || "source:#{ref.source_id}",
        refs: [ref],
        metadata: Map.merge(entry.source.metadata, %{source_id: ref.source_id})
      )
    end
  end

  def materialize(%__MODULE__{} = environment, %Slice{} = slice, opts) do
    with {:ok, entry} <- fetch_entry(environment, slice.source_ref) do
      content = String.slice(entry.content, slice.offset, slice.length)

      MaterializedArtifact.new(content,
        id: Keyword.get(opts, :id) || "slice:#{slice.id}",
        refs: [slice | slice.provenance],
        metadata:
          Map.merge(slice.metadata, %{
            source_id: slice.source_ref.source_id,
            slice_id: slice.id,
            offset: slice.offset,
            length: slice.length
          })
      )
    end
  end

  @impl true
  def delete(%__MODULE__{} = environment, %EnvironmentRef{} = ref) do
    {:ok, update_in(environment.sources, &Map.delete(&1, ref.source_id))}
  end

  defp next_id(%__MODULE__{} = environment), do: "source-#{map_size(environment.sources) + 1}"

  defp checksum(content), do: :erlang.phash2(content) |> Integer.to_string(16)

  defp fetch_entry(%__MODULE__{} = environment, %EnvironmentRef{} = ref) do
    case Map.fetch(environment.sources, ref.source_id) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        {:error,
         Error.validation("source not found in in-memory RLM environment",
           source: __MODULE__,
           details: %{source_id: ref.source_id}
         )}
    end
  end

  defp ensure_bounds(%Source{} = source, offset, length)
       when offset >= 0 and length >= 0 and offset + length <= source.size,
       do: :ok

  defp ensure_bounds(%Source{} = source, offset, length) do
    {:error,
     Error.validation("slice is outside source bounds",
       source: __MODULE__,
       details: %{source_id: source.id, source_size: source.size, offset: offset, length: length}
     )}
  end

  defp validate_chunking(chunk_size, overlap)
       when is_integer(chunk_size) and chunk_size > 0 and is_integer(overlap) and overlap >= 0 and
              overlap < chunk_size,
       do: :ok

  defp validate_chunking(chunk_size, overlap) do
    {:error,
     Error.validation("chunk_size must be positive and overlap must be smaller than chunk_size",
       source: __MODULE__,
       details: %{chunk_size: chunk_size, overlap: overlap}
     )}
  end

  defp validate_search(query, context)
       when query != "" and is_integer(context) and context >= 0,
       do: :ok

  defp validate_search(query, context) do
    {:error,
     Error.validation("search query must be non-empty and context must be non-negative",
       source: __MODULE__,
       details: %{query: query, context: context}
     )}
  end

  defp offsets(0, _chunk_size, _overlap), do: []

  defp offsets(size, chunk_size, overlap) do
    step = chunk_size - overlap

    Stream.iterate(0, &(&1 + step))
    |> Enum.take_while(&(&1 < size))
  end

  defp match_offsets(content, query) do
    query_length = String.length(query)
    max_offset = String.length(content) - query_length

    if max_offset < 0 do
      []
    else
      0..max_offset
      |> Enum.filter(&(String.slice(content, &1, query_length) == query))
    end
  end
end
