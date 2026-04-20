defmodule RunicAI.Steps.IngestContextTurn do
  @moduledoc """
  Incrementally ingest transcript messages into the durable context graph.
  """

  require Runic

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Context.Graph
  alias RunicAI.Context.Node
  alias RunicAI.Context.Ref
  alias RunicAI.Context.State, as: ContextState
  alias RunicAI.Message

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :ingest_context_turn)

    Runic.step(
      fn %TurnRequest{} = turn_request ->
        ingest!(turn_request)
      end,
      name: name
    )
  end

  @spec ingest(TurnRequest.t()) :: {:ok, TurnRequest.t()} | {:error, RunicAI.Error.t()}
  def ingest(%TurnRequest{} = turn_request) do
    with {:ok, turn_request} <- TurnRequest.validate(turn_request) do
      context = turn_request.state.context || ContextState.new!()
      ingested_count = Map.get(context.metadata, :ingested_message_count, 0)

      {graph, root_refs, active_refs, _previous_ref} =
        turn_request.state.conversation.messages
        |> Enum.with_index(1)
        |> Enum.reduce(
          {context.graph, context.root_refs, context.active_refs, nil},
          fn {message, index}, {graph, root_refs, active_refs, previous_ref} ->
            ref = message_ref(message, index)

            cond do
              index <= ingested_count and Graph.has_ref?(graph, ref) ->
                {graph, root_refs, active_refs, ref}

              true ->
                node =
                  Node.new_from_ref!(ref, message,
                    metadata: %{role: message.role, position: index}
                  )

                graph = Graph.put_node!(graph, node)
                graph = maybe_link_previous(graph, previous_ref, ref)

                root_refs =
                  if root_refs == [] do
                    [ref]
                  else
                    root_refs
                  end

                active_refs = unique_refs(active_refs ++ [ref])

                {graph, root_refs, active_refs, ref}
            end
          end
        )

      stats =
        context.stats
        |> Map.merge(%{
          message_count: Enum.count(Graph.list_nodes_by_kind(graph, :message)),
          observation_count: Enum.count(Graph.list_nodes_by_kind(graph, :observation))
        })

      context =
        context
        |> ContextState.with_graph!(graph)
        |> ContextState.put_refs!(root_refs: root_refs, active_refs: active_refs)
        |> Map.put(:stats, stats)
        |> Map.put(
          :metadata,
          context.metadata
          |> Map.put(:ingested_message_count, length(turn_request.state.conversation.messages))
          |> Map.put(:last_ingested_at, DateTime.utc_now())
        )

      state = State.with_context!(turn_request.state, context)
      TurnRequest.with_state(turn_request, state)
    end
  end

  @spec ingest!(TurnRequest.t()) :: TurnRequest.t()
  def ingest!(%TurnRequest{} = turn_request) do
    case ingest(turn_request) do
      {:ok, updated_turn_request} -> updated_turn_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp maybe_link_previous(graph, nil, _ref), do: graph

  defp maybe_link_previous(graph, %Ref{} = previous_ref, %Ref{} = ref) do
    Graph.add_relation!(graph, previous_ref, ref, :next,
      properties: %{derived_at: DateTime.utc_now()}
    )
  end

  defp message_ref(%Message{role: :tool}, index) do
    Ref.new!(:observation, index, label: "tool:#{index}", metadata: %{position: index})
  end

  defp message_ref(%Message{} = message, index) do
    Ref.new!(:message, index, label: "#{message.role}:#{index}", metadata: %{position: index})
  end

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
