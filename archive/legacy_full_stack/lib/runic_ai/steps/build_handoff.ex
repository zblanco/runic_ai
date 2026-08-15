defmodule RunicAI.Steps.BuildHandoff do
  @moduledoc """
  Build a focused handoff artifact for another conversation or workflow branch.
  """

  require Runic

  alias RunicAI.Agent.State
  alias RunicAI.Context.Focus
  alias RunicAI.Context.Graph
  alias RunicAI.Context.HandoffArtifact
  alias RunicAI.Context.HandoffRequest
  alias RunicAI.Context.Node
  alias RunicAI.Context.Ref
  alias RunicAI.Message

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :build_handoff)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn %State{} = state, request_or_focus ->
        build!(state, request_or_focus, defaults)
      end,
      name: name
    )
  end

  @spec build(State.t(), HandoffRequest.t() | Focus.t() | String.t(), keyword()) ::
          {:ok, HandoffArtifact.t()} | {:error, RunicAI.Error.t()}
  def build(%State{} = state, request_or_focus, opts \\ []) do
    with {:ok, state} <- State.validate(state),
         {:ok, request} <- normalize_request(request_or_focus, opts) do
      summary_lines = summary_lines(state)

      brief =
        [
          "Goal: #{request.goal}",
          "Audience: #{request.audience}",
          if(request.style_prompt, do: "Style: #{request.style_prompt}", else: nil),
          "Relevant context:",
          Enum.map_join(summary_lines, "\n", &("- " <> &1))
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      seed_messages =
        [
          Message.new!(:system, brief)
          | recent_tail_messages(state)
        ]
        |> trim_seed_messages(request.max_seed_tokens)

      references = if request.include_refs?, do: collect_refs(state), else: []

      HandoffArtifact.new(
        brief: brief,
        seed_messages: seed_messages,
        references: references,
        open_questions:
          (state.context && state.context.last_focus && state.context.last_focus.questions) || [],
        next_actions: ["Continue toward: #{request.goal}"],
        constraints:
          (state.context && state.context.last_focus && state.context.last_focus.constraints) ||
            [],
        metadata: %{request: request}
      )
    end
  end

  @spec build!(State.t(), HandoffRequest.t() | Focus.t() | String.t(), keyword()) ::
          HandoffArtifact.t()
  def build!(%State{} = state, request_or_focus, opts \\ []) do
    case build(state, request_or_focus, opts) do
      {:ok, artifact} -> artifact
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_request(%HandoffRequest{} = request, _opts), do: HandoffRequest.validate(request)

  defp normalize_request(%Focus{} = focus, opts) do
    HandoffRequest.new(
      goal: focus.goal,
      audience: Keyword.get(opts, :audience, "next_thread"),
      max_seed_tokens: Keyword.get(opts, :max_seed_tokens, 1_200),
      include_refs?: Keyword.get(opts, :include_refs?, true),
      style_prompt: Keyword.get(opts, :style_prompt, focus.salience_prompt),
      metadata: %{focus: focus}
    )
  end

  defp normalize_request(goal, opts) when is_binary(goal) do
    HandoffRequest.new(
      goal: goal,
      audience: Keyword.get(opts, :audience, "next_thread"),
      max_seed_tokens: Keyword.get(opts, :max_seed_tokens, 1_200),
      include_refs?: Keyword.get(opts, :include_refs?, true),
      style_prompt: Keyword.get(opts, :style_prompt)
    )
  end

  defp normalize_request(other, _opts) do
    {:error,
     RunicAI.Error.validation("unsupported handoff request input: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp summary_lines(%State{context: %{graph: %Graph{} = graph}}) do
    top_summaries =
      graph
      |> Graph.top_level_nodes(:summary)
      |> Enum.take(3)

    cond do
      top_summaries != [] ->
        Enum.map(top_summaries, &Node.text/1)

      true ->
        []
    end
  end

  defp summary_lines(%State{} = state) do
    state
    |> recent_tail_messages()
    |> Enum.map(& &1.content)
  end

  defp recent_tail_messages(%State{} = state) do
    state.conversation.messages
    |> Enum.reject(&(&1.role == :system))
    |> Enum.take(-4)
  end

  defp trim_seed_messages(messages, max_seed_tokens) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn message, {acc, tokens} ->
      next_tokens = tokens + Node.estimate_tokens(message)

      if next_tokens > max_seed_tokens and acc != [] do
        {:halt, {acc, tokens}}
      else
        {:cont, {[message | acc], next_tokens}}
      end
    end)
    |> elem(0)
  end

  defp collect_refs(%State{context: nil}), do: []

  defp collect_refs(%State{context: %{active_refs: active_refs, tail_refs: tail_refs}}) do
    active_refs
    |> Kernel.++(tail_refs)
    |> Enum.reduce({MapSet.new(), []}, fn %Ref{} = ref, {seen, acc} ->
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
