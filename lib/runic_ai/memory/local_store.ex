defmodule RunicAI.Memory.LocalStore do
  @moduledoc """
  Lightweight ETS-backed local memory store.

  This is intentionally small and process-local to the current BEAM. It gives
  local agent sessions a default Memory.Store implementation without requiring
  a database migration or external service.
  """

  @behaviour RunicAI.Memory.Store

  alias RunicAI.Context.Ref
  alias RunicAI.Memory.Entry
  alias RunicAI.Memory.Query
  alias RunicAI.Memory.ReadResult

  @table :runic_ai_memory_local_store

  @impl true
  def write(entries, opts \\ []) when is_list(entries) do
    table = ensure_table()
    namespace = namespace(opts)

    normalized =
      entries
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case Entry.validate(entry) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    case normalized do
      {:ok, entries} ->
        for %Entry{} = entry <- entries do
          :ets.insert(table, {{namespace, entry.id}, entry})
        end

        {:ok, %{namespace: namespace, count: length(entries)}}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def read(%Query{} = query, opts \\ []) do
    table = ensure_table()
    namespace = namespace(opts)

    entries =
      table
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{^namespace, _id}, %Entry{} = entry} -> [entry]
        _other -> []
      end)
      |> Enum.filter(&(&1.kind in query.kinds))
      |> Enum.filter(&Entry.active?/1)
      |> maybe_filter_query(query)
      |> Enum.sort_by(&{-memory_score(&1, query), &1.id})
      |> Enum.take(query.limit)

    refs =
      entries
      |> Enum.flat_map(& &1.refs)
      |> unique_refs()

    ReadResult.new(
      entries: entries,
      refs: refs,
      metadata: %{namespace: namespace, recalled: length(entries)}
    )
  end

  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    table = ensure_table()
    namespace = namespace(opts)

    table
    |> :ets.tab2list()
    |> Enum.each(fn
      {{^namespace, id}, _entry} -> :ets.delete(table, {namespace, id})
      _other -> :ok
    end)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      table ->
        table
    end
  rescue
    ArgumentError ->
      @table
  end

  defp namespace(opts), do: opts |> Keyword.get(:namespace, :default) |> to_string()

  defp maybe_filter_query(entries, %Query{focus: focus}) do
    terms =
      [focus.goal | focus.questions ++ focus.entities ++ focus.constraints]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.split(~r/[^a-z0-9_:-]+/u, trim: true)
      |> Enum.uniq()

    if terms == [] do
      entries
    else
      Enum.filter(entries, fn entry ->
        haystack = memory_text(entry) |> String.downcase()
        Enum.any?(terms, &(String.length(&1) > 1 and String.contains?(haystack, &1)))
      end)
    end
  end

  defp memory_score(%Entry{} = entry, %Query{focus: focus}) do
    haystack = memory_text(entry) |> String.downcase()

    terms =
      [focus.goal | focus.questions ++ focus.entities ++ focus.constraints]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.split(~r/[^a-z0-9_:-]+/u, trim: true)
      |> Enum.uniq()

    overlap = Enum.count(terms, &(String.length(&1) > 1 and String.contains?(haystack, &1)))
    entry.salience + overlap
  end

  defp memory_text(%Entry{} = entry), do: "#{entry.summary || ""} #{entry.content}"

  defp unique_refs(refs) do
    refs
    |> Enum.reduce({MapSet.new(), []}, fn ref, {seen, acc} ->
      key = Ref.key(ref)

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
