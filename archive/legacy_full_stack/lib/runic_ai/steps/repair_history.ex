defmodule RunicAI.Steps.RepairHistory do
  @moduledoc """
  Normalize and conservatively repair conversation history before prompt assembly.

  Repairs are intentionally local and deterministic:

  - normalize message values into `RunicAI.Message`
  - drop blank-content messages
  - deduplicate identical leading system messages
  """

  require Runic

  alias RunicAI.Agent.State, as: AgentState
  alias RunicAI.Conversation.State, as: ConversationState
  alias RunicAI.Message

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :repair_history)

    Runic.step(
      fn input ->
        repair!(input)
      end,
      name: name
    )
  end

  @spec repair([term()] | ConversationState.t() | AgentState.t()) ::
          {:ok, [Message.t()] | ConversationState.t() | AgentState.t()}
          | {:error, RunicAI.Error.t()}
  def repair(messages) when is_list(messages) do
    with {:ok, normalized_messages} <- Message.normalize_list(messages) do
      {:ok,
       normalized_messages
       |> drop_blank_messages()
       |> dedupe_leading_system_messages()}
    end
  end

  def repair(%ConversationState{} = state) do
    with {:ok, repaired_messages} <- repair(state.messages) do
      ConversationState.new(repaired_messages, status: state.status, assigns: state.assigns)
    end
  end

  def repair(%AgentState{} = state) do
    with {:ok, repaired_conversation} <- repair(state.conversation) do
      AgentState.with_conversation(state, repaired_conversation)
    end
  end

  @spec repair!([term()] | ConversationState.t() | AgentState.t()) ::
          [Message.t()] | ConversationState.t() | AgentState.t()
  def repair!(value) do
    case repair(value) do
      {:ok, repaired_value} -> repaired_value
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec repair_messages!([term()]) :: [Message.t()]
  def repair_messages!(messages) when is_list(messages) do
    case repair(messages) do
      {:ok, repaired_messages} -> repaired_messages
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp drop_blank_messages(messages) do
    Enum.reject(messages, fn message ->
      String.trim(message.content) == "" and not preserve_blank_message?(message)
    end)
  end

  defp dedupe_leading_system_messages(messages) do
    {system_prefix, remaining_messages} = Enum.split_while(messages, &(&1.role == :system))

    deduped_prefix =
      Enum.reduce(system_prefix, [], fn message, acc ->
        case acc do
          [last | _] when last == message -> acc
          _ -> [message | acc]
        end
      end)
      |> Enum.reverse()

    deduped_prefix ++ remaining_messages
  end

  defp preserve_blank_message?(%Message{role: :tool}), do: true

  defp preserve_blank_message?(%Message{metadata: metadata}) when is_map(metadata) do
    tool_calls = Map.get(metadata, :tool_calls)
    tool_call_id = Map.get(metadata, :tool_call_id)

    (is_list(tool_calls) and tool_calls != []) or is_binary(tool_call_id)
  end

  defp preserve_blank_message?(_message), do: false
end
