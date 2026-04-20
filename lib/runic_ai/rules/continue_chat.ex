defmodule RunicAI.Rules.ContinueChat do
  @moduledoc """
  Continuation decisions for the conversational kernel.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Error
  alias RunicAI.Message

  @type input :: %{state: State.t(), turn_result: TurnResult.t()}

  def input_step(opts \\ []) do
    name = Keyword.get(opts, :name, :continue_chat_input)

    Runic.step(
      fn %State{} = state, %TurnResult{} = turn_result ->
        bundle_input!(state, turn_result)
      end,
      name: name
    )
  end

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :continue_chat)
    options = Keyword.drop(opts, [:name])
    validated_input_name = :"#{name}_validated_input"

    validated_input_step =
      Runic.step(
        fn input ->
          validate_input!(input)
        end,
        name: validated_input_name
      )

    Workflow.new(name: name)
    |> Workflow.add(validated_input_step)
    |> add_rules(validated_input_name, name, options)
  end

  def rules(opts \\ []) do
    name = Keyword.get(opts, :name, :continue_chat)

    opts
    |> Keyword.drop([:name])
    |> build_rules(name)
  end

  @spec decide(State.t(), TurnResult.t(), keyword()) ::
          {:ok, ContinueDecision.t()} | {:error, Error.t()}
  def decide(%State{} = state, %TurnResult{} = turn_result, opts \\ []) do
    with {:ok, state} <- State.validate(state),
         {:ok, turn_result} <- TurnResult.validate(turn_result) do
      case custom_decision(state, turn_result, Keyword.get(opts, :continue_when)) do
        {:ok, %ContinueDecision{} = decision} ->
          {:ok, decision}

        :no_custom_decision ->
          default_decision(state, turn_result, opts)
      end
    end
  end

  @spec decide!(State.t(), TurnResult.t(), keyword()) :: ContinueDecision.t()
  def decide!(%State{} = state, %TurnResult{} = turn_result, opts \\ []) do
    case decide(state, turn_result, opts) do
      {:ok, decision} -> decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec bundle_input(State.t(), TurnResult.t()) :: {:ok, input()} | {:error, Error.t()}
  def bundle_input(%State{} = state, %TurnResult{} = turn_result) do
    with {:ok, state} <- State.validate(state),
         {:ok, turn_result} <- TurnResult.validate(turn_result) do
      {:ok, %{state: state, turn_result: turn_result}}
    end
  end

  @spec bundle_input!(State.t(), TurnResult.t()) :: input()
  def bundle_input!(%State{} = state, %TurnResult{} = turn_result) do
    case bundle_input(state, turn_result) do
      {:ok, bundled_input} -> bundled_input
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate_input(input()) :: {:ok, input()} | {:error, Error.t()}
  def validate_input(%{state: %State{} = state, turn_result: %TurnResult{} = turn_result}) do
    bundle_input(state, turn_result)
  end

  def validate_input(other) do
    {:error,
     Error.validation(
       "continue chat input must be %{state: Agent.State, turn_result: Agent.TurnResult}",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec validate_input!(input()) :: input()
  def validate_input!(input) do
    case validate_input(input) do
      {:ok, bundled_input} -> bundled_input
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp default_decision(%State{status: :halted}, _turn_result, _opts),
    do: ContinueDecision.halt(:halted)

  defp default_decision(%State{status: :completed}, _turn_result, _opts),
    do: ContinueDecision.stop(:completed)

  defp default_decision(state, %TurnResult{kind: :error}, _opts) do
    ContinueDecision.halt(:turn_error, metadata: %{turns: state.conversation.turns})
  end

  defp default_decision(state, _turn_result, opts) do
    cond do
      max_turns_reached?(state, Keyword.get(opts, :max_turns)) ->
        ContinueDecision.stop(:max_turns, metadata: %{turns: state.conversation.turns})

      stop_pattern_detected?(state, Keyword.get(opts, :stop_pattern)) ->
        ContinueDecision.stop(:stop_pattern, metadata: %{turns: state.conversation.turns})

      true ->
        ContinueDecision.continue(:continue, metadata: %{turns: state.conversation.turns})
    end
  end

  defp custom_decision(_state, _turn_result, nil), do: :no_custom_decision

  defp custom_decision(state, turn_result, fun) when is_function(fun, 2) do
    case ContinueDecision.from_value(fun.(state, turn_result), reason: :custom) do
      {:ok, decision} -> {:ok, decision}
      {:error, _error} -> :no_custom_decision
    end
  end

  defp max_turns_reached?(state, max_turns) do
    is_integer(max_turns) and max_turns >= 0 and state.conversation.turns >= max_turns
  end

  defp stop_pattern_detected?(state, pattern) do
    case {state.conversation.last_assistant_message, pattern} do
      {%Message{} = message, pattern} when not is_nil(pattern) ->
        matches_pattern?(message.content, pattern)

      _ ->
        false
    end
  end

  defp matches_pattern?(text, pattern) when is_binary(pattern),
    do: String.contains?(text, pattern)

  defp matches_pattern?(text, %Regex{} = pattern), do: String.match?(text, pattern)

  defp matches_pattern?(text, patterns) when is_list(patterns),
    do: Enum.any?(patterns, &matches_pattern?(text, &1))

  defp add_rules(workflow, input_name, name, opts) do
    Enum.reduce(build_rules(opts, name), workflow, fn rule, wrk ->
      Workflow.add(wrk, rule, to: input_name)
    end)
  end

  defp build_rules(opts, name) do
    continue_when = Keyword.get(opts, :continue_when)
    max_turns = Keyword.get(opts, :max_turns)
    stop_pattern = Keyword.get(opts, :stop_pattern)

    [
      custom_rule(name, continue_when),
      halted_rule(name, continue_when),
      completed_rule(name, continue_when),
      error_rule(name, continue_when),
      max_turns_rule(name, continue_when, max_turns),
      stop_pattern_rule(name, continue_when, max_turns, stop_pattern),
      continue_rule(name, continue_when, max_turns, stop_pattern)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp custom_rule(_name, nil), do: nil

  defp custom_rule(name, continue_when) do
    Runic.rule(
      name: :"#{name}_custom",
      condition: fn %{state: state, turn_result: turn_result} ->
        custom_decision_match?(state, turn_result, continue_when)
      end,
      reaction: fn %{state: state, turn_result: turn_result} ->
        custom_decision!(state, turn_result, continue_when)
      end
    )
  end

  defp halted_rule(name, continue_when) do
    Runic.rule(
      name: :"#{name}_halted",
      condition: fn %{state: state, turn_result: turn_result} ->
        no_custom_decision?(state, turn_result, continue_when) and state.status == :halted
      end,
      reaction: fn _input ->
        ContinueDecision.halt!(:halted)
      end
    )
  end

  defp completed_rule(name, continue_when) do
    Runic.rule(
      name: :"#{name}_completed",
      condition: fn %{state: state, turn_result: turn_result} ->
        no_custom_decision?(state, turn_result, continue_when) and state.status == :completed
      end,
      reaction: fn _input ->
        ContinueDecision.stop!(:completed)
      end
    )
  end

  defp error_rule(name, continue_when) do
    Runic.rule(
      name: :"#{name}_turn_error",
      condition: fn %{state: state, turn_result: turn_result} ->
        no_custom_decision?(state, turn_result, continue_when) and state.status == :running and
          turn_result.kind == :error
      end,
      reaction: fn %{state: state} ->
        ContinueDecision.halt!(:turn_error, metadata: %{turns: state.conversation.turns})
      end
    )
  end

  defp max_turns_rule(name, continue_when, max_turns) do
    Runic.rule(
      name: :"#{name}_max_turns",
      condition: fn %{state: state, turn_result: turn_result} ->
        no_custom_decision?(state, turn_result, continue_when) and state.status == :running and
          max_turns_reached?(state, max_turns)
      end,
      reaction: fn %{state: state} ->
        ContinueDecision.stop!(:max_turns, metadata: %{turns: state.conversation.turns})
      end
    )
  end

  defp stop_pattern_rule(name, continue_when, max_turns, stop_pattern) do
    Runic.rule(
      name: :"#{name}_stop_pattern",
      condition: fn %{state: state, turn_result: turn_result} ->
        no_custom_decision?(state, turn_result, continue_when) and state.status == :running and
          not max_turns_reached?(state, max_turns) and stop_pattern_detected?(state, stop_pattern)
      end,
      reaction: fn %{state: state} ->
        ContinueDecision.stop!(:stop_pattern, metadata: %{turns: state.conversation.turns})
      end
    )
  end

  defp continue_rule(name, continue_when, max_turns, stop_pattern) do
    Runic.rule(
      name: :"#{name}_continue",
      condition: fn %{state: state, turn_result: turn_result} ->
        no_custom_decision?(state, turn_result, continue_when) and state.status == :running and
          turn_result.kind != :error and not max_turns_reached?(state, max_turns) and
          not stop_pattern_detected?(state, stop_pattern)
      end,
      reaction: fn %{state: state} ->
        ContinueDecision.continue!(:continue, metadata: %{turns: state.conversation.turns})
      end
    )
  end

  defp custom_decision_match?(state, turn_result, continue_when) do
    match?({:ok, %ContinueDecision{}}, custom_decision(state, turn_result, continue_when))
  end

  defp no_custom_decision?(state, turn_result, continue_when) do
    custom_decision(state, turn_result, continue_when) == :no_custom_decision
  end

  defp custom_decision!(state, turn_result, continue_when) do
    case custom_decision(state, turn_result, continue_when) do
      {:ok, decision} -> decision
      :no_custom_decision -> raise ArgumentError, "no custom continue decision matched"
    end
  end
end
