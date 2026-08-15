defmodule RunicAI.Steps.EvaluateContextPressure do
  @moduledoc """
  Measure context pressure and decide whether to continue, compact, or hand off.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Context.Focus
  alias RunicAI.Context.Graph
  alias RunicAI.Context.Node
  alias RunicAI.Context.PressureDecision
  alias RunicAI.Context.PressureSnapshot
  alias RunicAI.Context.Ref
  alias RunicAI.Context.WindowPolicy
  alias RunicAI.Memory.ReadResult
  alias RunicAI.Message
  alias RunicAI.Retrieval.Result

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :evaluate_context_pressure)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnRequest{} = turn_request,
         %Focus{} = focus,
         %ReadResult{} = memory_result,
         %Result{} = retrieval_result ->
        evaluate!(turn_request, focus, memory_result, retrieval_result, options)
      end,
      name: name
    )
  end

  @spec evaluate(TurnRequest.t(), Focus.t(), ReadResult.t(), Result.t(), keyword()) ::
          {:ok, PressureDecision.t()} | {:error, RunicAI.Error.t()}
  def evaluate(
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
      context = turn_request.state.context
      tail_refs = select_tail_refs(turn_request.state.conversation.messages, policy)
      summary_tokens = summary_tokens(context)
      memory_tokens = memory_tokens(memory_result)
      retrieval_tokens = retrieval_tokens(retrieval_result)

      current_tokens =
        prompt_tokens(turn_request) + memory_tokens + retrieval_tokens + summary_tokens

      compactable_refs = compactable_refs(context, turn_request, tail_refs)

      snapshot =
        PressureSnapshot.new!(
          current_tokens: current_tokens,
          tail_tokens: tail_tokens(turn_request.state.conversation.messages, policy),
          summary_tokens: summary_tokens,
          memory_tokens: memory_tokens,
          retrieval_tokens: retrieval_tokens,
          compactable_refs: compactable_refs,
          metadata: %{
            focus: focus,
            tail_refs: tail_refs,
            available_tokens: max(policy.max_input_tokens - policy.reserve_output_tokens, 0),
            policy: policy
          }
        )

      decision(snapshot, policy, retrieval_result)
    end
  end

  @spec evaluate!(TurnRequest.t(), Focus.t(), ReadResult.t(), Result.t(), keyword()) ::
          PressureDecision.t()
  def evaluate!(
        %TurnRequest{} = turn_request,
        %Focus{} = focus,
        %ReadResult{} = memory_result,
        %Result{} = retrieval_result,
        opts \\ []
      ) do
    case evaluate(turn_request, focus, memory_result, retrieval_result, opts) do
      {:ok, decision} -> decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_policy(%WindowPolicy{} = policy), do: WindowPolicy.validate(policy)
  defp normalize_policy(opts) when is_list(opts), do: WindowPolicy.new(opts)

  defp decision(
         %PressureSnapshot{} = snapshot,
         %WindowPolicy{} = policy,
         %Result{} = retrieval_result
       ) do
    available_tokens = snapshot.metadata.available_tokens

    cond do
      snapshot.current_tokens <= min(policy.soft_pressure_tokens, available_tokens) ->
        PressureDecision.new(:none, "context is within the soft budget", snapshot: snapshot)

      snapshot.compactable_refs != [] ->
        PressureDecision.new(:compact, "older context can be summarized safely",
          snapshot: snapshot
        )

      policy.preferred_relief == :retrieve and retrieval_result.documents == [] ->
        PressureDecision.new(
          :retrieve,
          "context is pressured and no retrieval evidence is present",
          snapshot: snapshot
        )

      snapshot.current_tokens > min(policy.hard_pressure_tokens, available_tokens) ->
        PressureDecision.new(
          :handoff,
          "context exceeds the hard budget with no compactable history left",
          snapshot: snapshot
        )

      true ->
        PressureDecision.new(
          policy.preferred_relief,
          "preferred context relief strategy requested",
          snapshot: snapshot
        )
    end
  end

  defp prompt_tokens(%TurnRequest{} = turn_request) do
    turn_request
    |> TurnRequest.prompt_messages()
    |> Enum.map(&Node.estimate_tokens/1)
    |> Enum.sum()
  end

  defp summary_tokens(nil), do: 0

  defp summary_tokens(%{graph: %Graph{} = graph}) do
    graph
    |> Graph.top_level_nodes(:summary)
    |> Enum.map(& &1.token_count)
    |> Enum.sum()
  end

  defp memory_tokens(%ReadResult{} = result) do
    result.entries
    |> Enum.map(fn entry -> Node.estimate_tokens(entry.summary || entry.content) end)
    |> Enum.sum()
  end

  defp retrieval_tokens(%Result{} = result) do
    result.documents
    |> Enum.map(&Node.estimate_tokens(&1.content))
    |> Enum.sum()
  end

  defp tail_tokens(messages, %WindowPolicy{} = policy) do
    messages
    |> select_tail_messages(policy)
    |> Enum.map(&Node.estimate_tokens/1)
    |> Enum.sum()
  end

  defp select_tail_refs(messages, %WindowPolicy{} = policy) do
    messages
    |> Enum.with_index(1)
    |> Enum.reject(fn {message, _index} -> message.role == :system end)
    |> select_tail_pairs(policy)
    |> Enum.map(fn {message, index} -> message_ref(message, index) end)
  end

  defp compactable_refs(nil, %TurnRequest{} = turn_request, tail_refs) do
    turn_request.state.conversation.messages
    |> Enum.with_index(1)
    |> Enum.reject(fn {message, _index} -> message.role == :system end)
    |> Enum.map(fn {message, index} -> message_ref(message, index) end)
    |> Enum.reject(fn ref -> ref_in?(ref, tail_refs) end)
  end

  defp compactable_refs(%{graph: %Graph{} = graph}, %TurnRequest{} = turn_request, tail_refs) do
    turn_request.state.conversation.messages
    |> Enum.with_index(1)
    |> Enum.reject(fn {message, _index} -> message.role == :system end)
    |> Enum.map(fn {message, index} -> message_ref(message, index) end)
    |> Enum.reject(fn ref ->
      ref_in?(ref, tail_refs) or Graph.summarized?(graph, ref)
    end)
  end

  defp select_tail_messages(messages, %WindowPolicy{} = policy) do
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

  defp select_tail_pairs(pairs, %WindowPolicy{} = policy) do
    pairs
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0, 0}, fn {message, index}, {acc, count, tokens} ->
      next_tokens = tokens + Node.estimate_tokens(message)

      cond do
        count >= policy.fresh_tail_messages -> {:halt, {acc, count, tokens}}
        next_tokens > policy.fresh_tail_tokens and acc != [] -> {:halt, {acc, count, tokens}}
        true -> {:cont, {[{message, index} | acc], count + 1, next_tokens}}
      end
    end)
    |> elem(0)
  end

  defp message_ref(%Message{role: :tool}, index), do: Ref.new!(:observation, index)
  defp message_ref(%Message{}, index), do: Ref.new!(:message, index)

  defp ref_in?(%Ref{} = ref, refs) do
    Enum.any?(refs, &Ref.same_target?(ref, &1))
  end
end
