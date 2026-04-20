defmodule RunicAI.Conversation do
  @moduledoc """
  A Runic accumulator that maintains conversation history.

  Tracks a running `RunicAI.Conversation.State` across LLM interactions.

  ## State

      %RunicAI.Conversation.State{}

  ## Input

  Each turn can be one of:
  - `%{user: "text", assistant: "text" | %RunicAI.Message{} | %RunicAI.LLM.Result{}}`
  - `%{messages: [%RunicAI.Message{}, ...]}`

  ## Example

      require Runic
      alias Runic.Workflow

      convo = RunicAI.Conversation.new(name: :chat, system: "You are helpful")

      workflow = Workflow.new(name: :convo_test) |> Workflow.add(convo)
      workflow = Workflow.react_until_satisfied(workflow, %{
        user: "Hello",
        assistant: "Hi there!"
      })
  """

  require Runic

  alias RunicAI.Conversation.State
  alias RunicAI.LLM.Result
  alias RunicAI.Message

  @doc """
  Creates a new conversation accumulator.

  ## Options

  - `:name` — component name (default: `:conversation`)
  - `:system` — optional system prompt string
  """
  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :conversation)
    system = Keyword.get(opts, :system)
    init = init_state(system)

    Runic.accumulator(
      init,
      fn turn, state ->
        reduce_turn!(turn, state)
      end,
      name: name
    )
  end

  @doc "Checks if a conversation state has exceeded the given turn limit."
  def max_turns_reached?(state, max_turns) do
    state.turns >= max_turns
  end

  @doc "Checks if the last response contains the given stop pattern."
  def stop_pattern_detected?(state, pattern) do
    case state.last_assistant_message do
      nil -> false
      %Message{} = message -> String.contains?(message.content, pattern)
    end
  end

  defp init_state(nil) do
    State.new!()
  end

  defp init_state(system) do
    State.new!([Message.new!(:system, system)])
  end

  defp reduce_turn!(%{messages: messages}, %State{} = state) when is_list(messages) do
    State.append_messages!(state, messages)
  end

  defp reduce_turn!(%{user: user, assistant: assistant}, %State{} = state) do
    State.append_turn!(state, user, normalize_assistant(assistant))
  end

  defp reduce_turn!(turn, _state) do
    raise ArgumentError, "unsupported conversation turn input: #{inspect(turn)}"
  end

  defp normalize_assistant(%Result{message: %Message{} = message}), do: message
  defp normalize_assistant(assistant), do: assistant
end
