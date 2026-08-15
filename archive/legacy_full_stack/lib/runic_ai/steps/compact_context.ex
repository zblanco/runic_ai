defmodule RunicAI.Steps.CompactContext do
  @moduledoc """
  Apply summary-DAG compaction to older context when pressure requires it.
  """

  require Runic

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Context.CompactionPolicy
  alias RunicAI.Context.Focus
  alias RunicAI.Context.Graph
  alias RunicAI.Context.Node
  alias RunicAI.Context.PressureDecision
  alias RunicAI.Context.Ref
  alias RunicAI.Context.State, as: ContextState

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :compact_context)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnRequest{} = turn_request, %Focus{} = focus, %PressureDecision{} = decision ->
        compact!(turn_request, focus, decision, options)
      end,
      name: name
    )
  end

  @spec compact(TurnRequest.t(), Focus.t(), PressureDecision.t(), keyword()) ::
          {:ok, TurnRequest.t()} | {:error, RunicAI.Error.t()}
  def compact(
        %TurnRequest{} = turn_request,
        %Focus{} = focus,
        %PressureDecision{} = decision,
        opts \\ []
      ) do
    with {:ok, turn_request} <- TurnRequest.validate(turn_request),
         {:ok, focus} <- Focus.validate(focus),
         {:ok, decision} <- PressureDecision.validate(decision),
         {:ok, policy} <- normalize_policy(Keyword.get(opts, :policy, [])) do
      if decision.action != :compact or policy.strategy == :none do
        {:ok, turn_request}
      else
        context = turn_request.state.context || ContextState.new!()
        graph = context.graph

        compactable_nodes =
          Enum.map(decision.snapshot.compactable_refs, &Graph.get_node(graph, &1))

        compactable_nodes = Enum.reject(compactable_nodes, &is_nil/1)

        if compactable_nodes == [] do
          {:ok, turn_request}
        else
          {graph, next_summary_id} =
            compactable_nodes
            |> chunk_nodes(policy.leaf_target_tokens)
            |> Enum.reduce({graph, Map.get(context.metadata, :next_summary_id, 1)}, fn chunk,
                                                                                       {graph,
                                                                                        next_id} ->
              {graph, next_id} = insert_summary(graph, chunk, next_id, focus, policy, opts)
              {graph, next_id}
            end)

          {graph, next_summary_id} =
            maybe_condense(graph, next_summary_id, focus, policy, opts)

          active_refs =
            graph
            |> Graph.top_level_nodes(:summary)
            |> Enum.map(&Node.ref/1)
            |> Kernel.++(Map.get(decision.snapshot.metadata, :tail_refs, []))
            |> unique_refs()

          context =
            context
            |> ContextState.with_graph!(graph)
            |> ContextState.with_focus!(focus)
            |> ContextState.put_refs!(
              active_refs: active_refs,
              tail_refs: Map.get(decision.snapshot.metadata, :tail_refs, [])
            )
            |> Map.put(
              :stats,
              context.stats
              |> Map.put(:summary_count, Enum.count(Graph.list_nodes_by_kind(graph, :summary)))
              |> Map.update(:compacted_count, 1, &(&1 + 1))
            )
            |> Map.put(
              :metadata,
              context.metadata
              |> Map.put(:next_summary_id, next_summary_id)
              |> Map.put(:last_compacted_at, DateTime.utc_now())
            )

          state = State.with_context!(turn_request.state, context)
          TurnRequest.with_state(turn_request, state)
        end
      end
    end
  end

  @spec compact!(TurnRequest.t(), Focus.t(), PressureDecision.t(), keyword()) :: TurnRequest.t()
  def compact!(
        %TurnRequest{} = turn_request,
        %Focus{} = focus,
        %PressureDecision{} = decision,
        opts \\ []
      ) do
    case compact(turn_request, focus, decision, opts) do
      {:ok, updated_turn_request} -> updated_turn_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_policy(%CompactionPolicy{} = policy), do: CompactionPolicy.validate(policy)
  defp normalize_policy(opts) when is_list(opts), do: CompactionPolicy.new(opts)

  defp chunk_nodes(nodes, leaf_target_tokens) do
    source_limit = max(leaf_target_tokens * 3, leaf_target_tokens + 1)

    {chunks, current_chunk, _current_tokens} =
      Enum.reduce(nodes, {[], [], 0}, fn node, {chunks, current_chunk, current_tokens} ->
        next_tokens = current_tokens + node.token_count

        cond do
          current_chunk != [] and next_tokens > source_limit ->
            {chunks ++ [current_chunk], [node], node.token_count}

          true ->
            {chunks, current_chunk ++ [node], next_tokens}
        end
      end)

    chunks ++ if(current_chunk == [], do: [], else: [current_chunk])
  end

  defp insert_summary(graph, chunk, next_id, focus, policy, opts) do
    source_refs = Enum.map(chunk, &Node.ref/1)
    depth = summary_depth(chunk)
    summary_ref = Ref.new!(:summary, Integer.to_string(next_id), label: "summary:#{next_id}")

    summary_node =
      Node.new_from_ref!(summary_ref, summarize_chunk(chunk, focus, policy, opts),
        metadata: %{
          depth: depth,
          source_refs: source_refs,
          focus_goal: focus.goal
        }
      )

    graph =
      source_refs
      |> Enum.reduce(Graph.put_node!(graph, summary_node), fn source_ref, acc ->
        Graph.add_relation!(acc, summary_ref, source_ref, :summarizes)
      end)

    {graph, next_id + 1}
  end

  defp maybe_condense(
         graph,
         next_summary_id,
         _focus,
         %CompactionPolicy{max_depth_per_pass: depth},
         _opts
       )
       when depth <= 0,
       do: {graph, next_summary_id}

  defp maybe_condense(graph, next_summary_id, focus, %CompactionPolicy{} = policy, opts) do
    top_level_leaf_summaries =
      graph
      |> Graph.top_level_nodes(:summary)
      |> Enum.filter(&(Map.get(&1.metadata, :depth, 0) == 0))

    if length(top_level_leaf_summaries) > 2 do
      insert_summary(
        graph,
        top_level_leaf_summaries,
        next_summary_id,
        focus,
        %{policy | leaf_target_tokens: policy.condensed_target_tokens},
        opts
      )
    else
      {graph, next_summary_id}
    end
  end

  defp summary_depth(nodes) do
    nodes
    |> Enum.map(&Map.get(&1.metadata, :depth, -1))
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  defp summarize_chunk(chunk, %Focus{} = focus, %CompactionPolicy{} = policy, opts) do
    summarizer = Keyword.get(opts, :summarizer)

    cond do
      is_function(summarizer, 3) ->
        summarizer.(chunk, focus, policy)

      is_atom(summarizer) and function_exported?(summarizer, :summarize, 3) ->
        summarizer.summarize(chunk, focus, policy)

      true ->
        default_summary(chunk, focus, policy)
    end
  end

  defp default_summary(chunk, %Focus{} = focus, %CompactionPolicy{} = policy) do
    target_chars = policy.leaf_target_tokens * 4

    lines =
      chunk
      |> Enum.map(fn node ->
        prefix =
          case node.kind do
            :message -> "[message]"
            :observation -> "[observation]"
            :summary -> "[summary]"
            other -> "[#{other}]"
          end

        "#{prefix} #{truncate(Node.text(node), 160)}"
      end)

    text =
      [
        "Goal: #{focus.goal}",
        "Relevant prior context:",
        Enum.map_join(lines, "\n", &("- " <> &1))
      ]
      |> Enum.join("\n")

    truncate(text, target_chars)
  end

  defp truncate(text, max_chars) when is_binary(text) and byte_size(text) <= max_chars, do: text
  defp truncate(text, max_chars), do: binary_part(text, 0, max(max_chars - 3, 0)) <> "..."

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
