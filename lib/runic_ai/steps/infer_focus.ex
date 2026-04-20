defmodule RunicAI.Steps.InferFocus do
  @moduledoc """
  Infer a focus contract from the current turn and any caller-supplied hint.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Context.Focus
  alias RunicAI.Message

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :infer_focus)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnRequest{} = turn_request, explicit_focus ->
        infer!(turn_request, explicit_focus, defaults)
      end,
      name: name
    )
  end

  @spec infer(TurnRequest.t(), term(), keyword()) ::
          {:ok, Focus.t()} | {:error, RunicAI.Error.t()}
  def infer(%TurnRequest{} = turn_request, explicit_focus, opts \\ []) do
    inferer = Keyword.get(opts, :inferer)

    with {:ok, turn_request} <- TurnRequest.validate(turn_request) do
      cond do
        explicit_focus not in [nil, ""] ->
          coerce_focus(explicit_focus)

        is_function(inferer, 1) ->
          coerce_focus(inferer.(turn_request))

        true ->
          auto_focus(turn_request, opts)
      end
    end
  end

  @spec infer!(TurnRequest.t(), term(), keyword()) :: Focus.t()
  def infer!(%TurnRequest{} = turn_request, explicit_focus, opts \\ []) do
    case infer(turn_request, explicit_focus, opts) do
      {:ok, focus} -> focus
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp coerce_focus(%Focus{} = focus), do: Focus.validate(focus)

  defp coerce_focus(text) when is_binary(text),
    do: Focus.new(goal: text, questions: maybe_question(text))

  defp coerce_focus(%{goal: goal} = map) do
    Focus.new(
      goal: goal,
      questions: Map.get(map, :questions, []),
      entities: Map.get(map, :entities, []),
      constraints: Map.get(map, :constraints, []),
      time_scope: Map.get(map, :time_scope),
      salience_prompt: Map.get(map, :salience_prompt),
      metadata: Map.get(map, :metadata, %{})
    )
  end

  defp coerce_focus(other) do
    {:error,
     RunicAI.Error.validation("unsupported focus input: #{inspect(other)}", source: __MODULE__)}
  end

  defp auto_focus(%TurnRequest{input_message: %Message{} = message} = turn_request, opts) do
    goal = String.trim(message.content)

    Focus.new(
      goal: goal,
      questions: maybe_question(goal),
      entities: infer_entities(goal),
      constraints: Keyword.get(opts, :constraints, []),
      salience_prompt: Keyword.get(opts, :salience_prompt)
    )
    |> maybe_use_state_focus(turn_request.state.context)
  end

  defp auto_focus(%TurnRequest{} = turn_request, opts) do
    fallback_goal =
      turn_request.state.context
      |> case do
        %{last_focus: %Focus{goal: goal}} -> goal
        _ -> Keyword.get(opts, :default_goal, "continue the current conversation")
      end

    Focus.new(goal: fallback_goal, salience_prompt: Keyword.get(opts, :salience_prompt))
  end

  defp maybe_use_state_focus({:ok, %Focus{} = focus}, %{last_focus: %Focus{} = previous_focus}) do
    Focus.new(
      goal: focus.goal,
      questions: Enum.uniq(focus.questions ++ previous_focus.questions),
      entities: Enum.uniq(focus.entities ++ previous_focus.entities),
      constraints: Enum.uniq(focus.constraints ++ previous_focus.constraints),
      salience_prompt: focus.salience_prompt || previous_focus.salience_prompt,
      metadata: Map.merge(previous_focus.metadata, focus.metadata)
    )
  end

  defp maybe_use_state_focus(result, _context), do: result

  defp maybe_question(text) do
    if String.contains?(text, "?"), do: [text], else: []
  end

  defp infer_entities(text) do
    text
    |> then(&Regex.scan(~r/\b[A-Z][a-zA-Z0-9_-]+\b/, &1))
    |> List.flatten()
    |> Enum.uniq()
  end
end
