defmodule RunicAI.Steps.AssembleContextBundle do
  @moduledoc """
  Assemble a typed active context bundle from transcript, summaries, memory,
  and retrieval evidence.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Context.Bundle
  alias RunicAI.Context.Focus
  alias RunicAI.Context.Graph
  alias RunicAI.Context.Node
  alias RunicAI.Context.Ref
  alias RunicAI.Context.WindowPolicy
  alias RunicAI.Memory.Entry
  alias RunicAI.Memory.ReadResult
  alias RunicAI.Message
  alias RunicAI.Retrieval.Document
  alias RunicAI.Retrieval.Result

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :assemble_context_bundle)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnRequest{} = turn_request,
         %Focus{} = focus,
         %ReadResult{} = memory_result,
         %Result{} = retrieval_result ->
        assemble!(turn_request, focus, memory_result, retrieval_result, options)
      end,
      name: name
    )
  end

  @spec assemble(TurnRequest.t(), Focus.t(), ReadResult.t(), Result.t(), keyword()) ::
          {:ok, Bundle.t()} | {:error, RunicAI.Error.t()}
  def assemble(
        %TurnRequest{} = turn_request,
        %Focus{} = focus,
        %ReadResult{} = memory_result,
        %Result{} = retrieval_result,
        opts \\ []
      ) do
    with {:ok, turn_request} <- TurnRequest.validate(turn_request),
         {:ok, focus} <- Focus.validate(focus),
         {:ok, memory_result} <- ReadResult.validate(memory_result),
         {:ok, retrieval_result} <- Result.validate(retrieval_result),
         {:ok, policy} <- normalize_policy(Keyword.get(opts, :window_policy, [])) do
      system_messages =
        leading_system_messages(turn_request.state.conversation.messages) ++
          turn_request.pinned_messages

      summary_nodes =
        case turn_request.state.context do
          %{graph: %Graph{} = graph} -> Graph.top_level_nodes(graph, :summary)
          _ -> []
        end

      raw_messages =
        case summary_nodes do
          [] ->
            turn_request
            |> TurnRequest.history_messages()
            |> Enum.reject(&(&1.role == :system))

          _ ->
            fresh_tail_messages(turn_request.state.conversation.messages, policy)
        end

      memory_messages = Enum.map(memory_result.entries, &memory_message/1)
      retrieval_messages = Enum.map(retrieval_result.documents, &retrieval_message/1)
      summary_messages = Enum.map(summary_nodes, &summary_message/1)

      messages =
        system_messages ++
          memory_messages ++
          retrieval_messages ++
          summary_messages ++
          raw_messages ++ maybe_wrap(turn_request.input_message) ++ turn_request.observations

      refs =
        summary_nodes
        |> Enum.map(&Node.ref/1)
        |> Kernel.++(memory_result.refs)
        |> Kernel.++(
          Enum.map(
            retrieval_result.documents,
            &Ref.new!(:retrieval, &1.id, metadata: %{uri: &1.uri})
          )
        )
        |> unique_refs()

      entries =
        []
        |> append_entries(:memory, memory_result.entries, fn entry ->
          %{
            kind: :memory,
            ref: List.first(entry.refs),
            token_count: Node.estimate_tokens(entry.summary || entry.content),
            value: entry
          }
        end)
        |> append_entries(:retrieval, retrieval_result.documents, fn document ->
          %{
            kind: :retrieval,
            ref: Ref.new!(:retrieval, document.id),
            token_count: Node.estimate_tokens(document.content),
            value: document
          }
        end)
        |> append_entries(:summary, summary_nodes, fn node ->
          %{kind: :summary, ref: Node.ref(node), token_count: node.token_count, value: node}
        end)

      coverage =
        %{
          history_messages: Enum.count(raw_messages),
          summary_count: length(summary_nodes),
          memory_entries: length(memory_result.entries),
          retrieval_documents: length(retrieval_result.documents)
        }

      Bundle.new(
        entries: entries,
        messages: messages,
        refs: refs,
        focus: focus,
        coverage: coverage,
        metadata: %{window_policy: policy}
      )
    end
  end

  @spec assemble!(TurnRequest.t(), Focus.t(), ReadResult.t(), Result.t(), keyword()) :: Bundle.t()
  def assemble!(
        %TurnRequest{} = turn_request,
        %Focus{} = focus,
        %ReadResult{} = memory_result,
        %Result{} = retrieval_result,
        opts \\ []
      ) do
    case assemble(turn_request, focus, memory_result, retrieval_result, opts) do
      {:ok, bundle} -> bundle
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_policy(%WindowPolicy{} = policy), do: WindowPolicy.validate(policy)
  defp normalize_policy(opts) when is_list(opts), do: WindowPolicy.new(opts)

  defp leading_system_messages(messages) do
    Enum.take_while(messages, &(&1.role == :system))
  end

  defp fresh_tail_messages(messages, %WindowPolicy{} = policy) do
    messages
    |> Enum.reject(&(&1.role == :system))
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0, 0}, fn message, {acc, count, tokens} ->
      next_tokens = tokens + Node.estimate_tokens(message)

      cond do
        count >= policy.fresh_tail_messages -> {:halt, {acc, count, tokens}}
        next_tokens > policy.fresh_tail_tokens and acc != [] -> {:halt, {acc, count, tokens}}
        true -> {:cont, {[message | acc], count + 1, next_tokens}}
      end
    end)
    |> elem(0)
  end

  defp summary_message(%Node{} = node) do
    Message.new!(:system, "[CONTEXT SUMMARY]\n" <> Node.text(node),
      metadata: %{context_ref: Ref.key(Node.ref(node))}
    )
  end

  defp memory_message(%Entry{} = entry) do
    Message.new!(:system, "[MEMORY #{entry.kind}]\n" <> (entry.summary || entry.content))
  end

  defp retrieval_message(%Document{} = document) do
    prefix =
      case document.uri do
        nil -> "[RETRIEVED]"
        uri -> "[RETRIEVED #{uri}]"
      end

    Message.new!(:system, prefix <> "\n" <> document.content,
      metadata: %{uri: document.uri, score: document.score}
    )
  end

  defp maybe_wrap(nil), do: []
  defp maybe_wrap(value), do: [value]

  defp append_entries(entries, _kind, [], _builder), do: entries

  defp append_entries(entries, _kind, items, builder) do
    entries ++ Enum.map(items, builder)
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
