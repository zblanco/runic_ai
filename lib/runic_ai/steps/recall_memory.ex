defmodule RunicAI.Steps.RecallMemory do
  @moduledoc """
  Recall memory entries from the current context state and optional store.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Context.Focus
  alias RunicAI.Context.Graph
  alias RunicAI.Memory.Entry
  alias RunicAI.Memory.Query
  alias RunicAI.Memory.ReadResult

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :recall_memory)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnRequest{} = turn_request, %Focus{} = focus ->
        recall!(turn_request, focus, options)
      end,
      name: name
    )
  end

  @spec recall(TurnRequest.t(), Focus.t(), keyword()) ::
          {:ok, ReadResult.t()} | {:error, RunicAI.Error.t()}
  def recall(%TurnRequest{} = turn_request, %Focus{} = focus, opts \\ []) do
    with {:ok, turn_request} <- TurnRequest.validate(turn_request),
         {:ok, focus} <- Focus.validate(focus),
         {:ok, query} <-
           Query.new(
             focus: focus,
             kinds: Keyword.get(opts, :kinds, [:episodic, :semantic, :temporal]),
             limit: Keyword.get(opts, :limit, 6),
             predicate: Keyword.get(opts, :predicate),
             metadata: Keyword.get(opts, :metadata, %{})
           ) do
      local_entries = local_entries(turn_request)
      store_entries = store_entries(query, opts)

      entries =
        (local_entries ++ store_entries)
        |> Enum.filter(&memory_kind_allowed?(&1, query.kinds))
        |> Enum.filter(&Entry.active?/1)
        |> maybe_filter(query.predicate)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&{-memory_score(&1, focus), &1.id})
        |> Enum.take(query.limit)

      refs =
        entries
        |> Enum.flat_map(& &1.refs)
        |> unique_refs()

      ReadResult.new(
        entries: entries,
        refs: refs,
        metadata: %{query: query, recalled: length(entries)}
      )
    end
  end

  @spec recall!(TurnRequest.t(), Focus.t(), keyword()) :: ReadResult.t()
  def recall!(%TurnRequest{} = turn_request, %Focus{} = focus, opts \\ []) do
    case recall(turn_request, focus, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp local_entries(%TurnRequest{state: %{context: nil}}), do: []

  defp local_entries(%TurnRequest{state: %{context: %{graph: %Graph{} = graph}}}) do
    graph
    |> Graph.list_nodes_by_kind(:memory)
    |> Enum.map(fn node -> node.content end)
    |> Enum.filter(&match?(%Entry{}, &1))
  end

  defp store_entries(%Query{} = query, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        []

      entries when is_list(entries) ->
        Enum.filter(entries, &match?(%Entry{}, &1))

      store when is_function(store, 2) ->
        case store.(query, Keyword.get(opts, :store_opts, [])) do
          {:ok, %ReadResult{entries: entries}} -> entries
          {:ok, entries} when is_list(entries) -> entries
          _ -> []
        end

      store when is_atom(store) ->
        case store.read(query, Keyword.get(opts, :store_opts, [])) do
          {:ok, %ReadResult{entries: entries}} -> entries
          _ -> []
        end
    end
  end

  defp memory_kind_allowed?(%Entry{kind: kind}, allowed_kinds), do: kind in allowed_kinds

  defp maybe_filter(entries, nil), do: entries
  defp maybe_filter(entries, predicate), do: Enum.filter(entries, predicate)

  defp memory_score(%Entry{} = entry, %Focus{} = focus) do
    haystack =
      entry
      |> memory_text()
      |> String.downcase()

    query_terms =
      [focus.goal | focus.questions ++ focus.entities ++ focus.constraints]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.split(~r/[^a-z0-9_:-]+/u, trim: true)
      |> Enum.uniq()

    overlap =
      Enum.count(query_terms, fn term ->
        term != "" and String.contains?(haystack, term)
      end)

    entry.salience + overlap
  end

  defp memory_text(%Entry{} = entry), do: "#{entry.summary || ""} #{entry.content}"

  defp unique_refs(refs) do
    refs
    |> Enum.reduce({MapSet.new(), []}, fn ref, {seen, acc} ->
      key = RunicAI.Context.Ref.key(ref)

      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        {MapSet.put(seen, key), [ref | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
