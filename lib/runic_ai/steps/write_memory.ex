defmodule RunicAI.Steps.WriteMemory do
  @moduledoc """
  Write episodic and simple semantic memory entries back into context state.
  """

  require Runic

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Context.Graph
  alias RunicAI.Context.Node
  alias RunicAI.Context.Ref
  alias RunicAI.Context.State, as: ContextState
  alias RunicAI.Memory.Entry
  alias RunicAI.Message
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallResult

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :write_memory)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %State{} = state, source ->
        write!(state, source, options)
      end,
      name: name
    )
  end

  @spec write(State.t(), term(), keyword()) :: {:ok, State.t()} | {:error, RunicAI.Error.t()}
  def write(%State{} = state, source, opts \\ []) do
    with {:ok, state} <- State.validate(state),
         {:ok, entries} <- extract_entries(state, source, opts) do
      if entries == [] do
        {:ok, state}
      else
        context = state.context || ContextState.new!()

        {graph, next_memory_id} =
          insert_entries(context.graph, entries, Map.get(context.metadata, :next_memory_id, 1))

        :ok = maybe_write_external(entries, opts)

        context =
          context
          |> ContextState.with_graph!(graph)
          |> Map.put(
            :stats,
            Map.put(
              context.stats,
              :memory_count,
              Enum.count(Graph.list_nodes_by_kind(graph, :memory))
            )
          )
          |> Map.put(:metadata, Map.put(context.metadata, :next_memory_id, next_memory_id))

        State.with_context(state, context)
      end
    end
  end

  @spec write!(State.t(), term(), keyword()) :: State.t()
  def write!(%State{} = state, source, opts \\ []) do
    case write(state, source, opts) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp extract_entries(%State{} = state, source, opts) do
    extractor = Keyword.get(opts, :extractor)

    cond do
      is_function(extractor, 2) ->
        normalize_entries(extractor.(state, source))

      match?(%TurnResult{}, source) ->
        normalize_entries(entries_from_turn_result(state, source))

      match?(%BatchResult{}, source) ->
        normalize_entries(entries_from_batch_result(state, source))

      true ->
        {:ok, []}
    end
  end

  defp normalize_entries(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case Entry.validate(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_entries(_), do: {:ok, []}

  defp entries_from_turn_result(%State{} = state, %TurnResult{} = turn_result) do
    assistant_entry =
      case turn_result.message do
        %Message{role: :assistant, content: content} ->
          [
            Entry.new!(
              kind: :episodic,
              content: content,
              summary: summarize_text(content),
              refs: latest_message_refs(state, [:assistant]),
              salience: if(turn_result.kind == :final, do: 0.85, else: 0.6),
              metadata: %{turn_kind: turn_result.kind}
            )
          ]

        _ ->
          []
      end

    semantic_entries =
      case latest_user_message(state) do
        %Message{content: content} -> extract_semantic_entries(content, state)
        _ -> []
      end

    assistant_entry ++ semantic_entries
  end

  defp entries_from_batch_result(%State{} = state, %BatchResult{results: results}) do
    if results == [] do
      []
    else
      tool_summary =
        results
        |> Enum.map(fn %CallResult{request: request, status: status} ->
          "#{request.tool_name}: #{status}"
        end)
        |> Enum.join(", ")

      [
        Entry.new!(
          kind: :episodic,
          content: tool_summary,
          summary: "Tool activity: #{tool_summary}",
          refs: latest_message_refs(state, [:tool]),
          salience: 0.7,
          metadata: %{tool_calls: length(results)}
        )
      ]
    end
  end

  defp insert_entries(graph, entries, next_memory_id) do
    Enum.reduce(entries, {graph, next_memory_id}, fn entry, {graph, next_id} ->
      entry = if entry.id =~ "memory-", do: %{entry | id: "memory-#{next_id}"}, else: entry
      ref = Ref.new!(:memory, entry.id, label: entry.summary || entry.content)
      node = Node.new_from_ref!(ref, entry, metadata: %{entry: entry})

      graph =
        entry.refs
        |> Enum.reduce(Graph.put_node!(graph, node), fn source_ref, acc ->
          if Graph.has_ref?(acc, source_ref) do
            Graph.add_relation!(acc, ref, source_ref, :memory_source)
          else
            acc
          end
        end)

      {graph, next_id + 1}
    end)
  end

  defp maybe_write_external(entries, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        :ok

      store when is_function(store, 2) ->
        _ = store.(entries, Keyword.get(opts, :store_opts, []))
        :ok

      store when is_atom(store) ->
        _ = store.write(entries, Keyword.get(opts, :store_opts, []))
        :ok

      _ ->
        :ok
    end
  end

  defp latest_message_refs(%State{} = state, roles) do
    state.conversation.messages
    |> Enum.with_index(1)
    |> Enum.filter(fn {message, _index} -> message.role in roles end)
    |> Enum.take(-2)
    |> Enum.map(fn {message, index} ->
      case message.role do
        :tool -> Ref.new!(:observation, index)
        _ -> Ref.new!(:message, index)
      end
    end)
  end

  defp latest_user_message(%State{} = state) do
    state.conversation.messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :user))
  end

  defp extract_semantic_entries(text, %State{} = state) do
    semantic_patterns = [
      ~r/\bmy ([a-z0-9 _-]+?) is ([^.?!]+)/i,
      ~r/\bremember that ([^.?!]+)/i
    ]

    semantic_patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, text)
      |> Enum.map(fn
        [_, attribute, value] ->
          summary = "User #{String.trim(attribute)} is #{String.trim(value)}"

          Entry.new!(
            kind: :semantic,
            content: summary,
            summary: summary,
            refs: latest_message_refs(state, [:user]),
            salience: 0.9,
            metadata: %{source: :pattern}
          )

        [_, remembered] ->
          summary = "Remembered fact: #{String.trim(remembered)}"

          Entry.new!(
            kind: :semantic,
            content: summary,
            summary: summary,
            refs: latest_message_refs(state, [:user]),
            salience: 0.9,
            metadata: %{source: :pattern}
          )
      end)
    end)
  end

  defp summarize_text(text) when byte_size(text) <= 160, do: text
  defp summarize_text(text), do: binary_part(text, 0, 157) <> "..."
end
