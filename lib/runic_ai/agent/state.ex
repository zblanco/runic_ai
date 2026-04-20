defmodule RunicAI.Agent.State do
  @moduledoc """
  Durable state for the conversational agent kernel.
  """

  alias RunicAI.Agent.TurnResult
  alias RunicAI.Conversation.State, as: ConversationState
  alias RunicAI.Context.State, as: ContextState
  alias RunicAI.Error
  alias RunicAI.Message

  @valid_statuses [:running, :completed, :halted]

  @enforce_keys [:conversation, :status, :assigns, :metadata]
  defstruct [
    :conversation,
    :context,
    :status,
    :pending_action,
    :last_turn_result,
    :assigns,
    :metadata
  ]

  @type status :: :running | :completed | :halted

  @type t :: %__MODULE__{
          conversation: ConversationState.t(),
          context: ContextState.t() | nil,
          status: status(),
          pending_action: term() | nil,
          last_turn_result: TurnResult.t() | nil,
          assigns: map(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    status = Keyword.get(opts, :status, :running)
    assigns = Keyword.get(opts, :assigns, %{})
    metadata = Keyword.get(opts, :metadata, %{})
    context = Keyword.get(opts, :context)
    pending_action = Keyword.get(opts, :pending_action)
    last_turn_result = Keyword.get(opts, :last_turn_result)

    with {:ok, conversation} <- build_conversation(opts),
         {:ok, context} <- normalize_context(context),
         :ok <- validate_status(status),
         :ok <- validate_assigns(assigns),
         :ok <- validate_metadata(metadata),
         {:ok, normalized_turn_result} <- normalize_last_turn_result(last_turn_result) do
      {:ok,
       %__MODULE__{
         conversation: conversation,
         context: context,
         status: status,
         pending_action: pending_action,
         last_turn_result: normalized_turn_result,
         assigns: assigns,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, state} -> state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = state) do
    with {:ok, _conversation} <- ConversationState.validate(state.conversation),
         {:ok, _context} <- normalize_context(state.context),
         :ok <- validate_status(state.status),
         :ok <- validate_assigns(state.assigns),
         :ok <- validate_metadata(state.metadata),
         {:ok, _turn_result} <- normalize_last_turn_result(state.last_turn_result) do
      {:ok, state}
    end
  end

  @spec with_conversation(t(), ConversationState.t()) :: {:ok, t()} | {:error, Error.t()}
  def with_conversation(%__MODULE__{} = state, %ConversationState{} = conversation) do
    with {:ok, conversation} <- ConversationState.validate(conversation) do
      {:ok, %__MODULE__{state | conversation: conversation}}
    end
  end

  @spec with_conversation!(t(), ConversationState.t()) :: t()
  def with_conversation!(%__MODULE__{} = state, %ConversationState{} = conversation) do
    case with_conversation(state, conversation) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec with_context(t(), ContextState.t() | nil) :: {:ok, t()} | {:error, Error.t()}
  def with_context(%__MODULE__{} = state, context) do
    with {:ok, normalized_context} <- normalize_context(context) do
      {:ok, %__MODULE__{state | context: normalized_context}}
    end
  end

  @spec with_context!(t(), ContextState.t() | nil) :: t()
  def with_context!(%__MODULE__{} = state, context) do
    case with_context(state, context) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec with_status(t(), status()) :: {:ok, t()} | {:error, Error.t()}
  def with_status(%__MODULE__{} = state, status) do
    with :ok <- validate_status(status) do
      {:ok, %__MODULE__{state | status: status}}
    end
  end

  @spec with_status!(t(), status()) :: t()
  def with_status!(%__MODULE__{} = state, status) do
    case with_status(state, status) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec with_last_turn_result(t(), TurnResult.t()) :: {:ok, t()} | {:error, Error.t()}
  def with_last_turn_result(%__MODULE__{} = state, %TurnResult{} = turn_result) do
    with {:ok, normalized_turn_result} <- TurnResult.validate(turn_result) do
      {:ok, %__MODULE__{state | last_turn_result: normalized_turn_result}}
    end
  end

  @spec with_last_turn_result!(t(), TurnResult.t()) :: t()
  def with_last_turn_result!(%__MODULE__{} = state, %TurnResult{} = turn_result) do
    case with_last_turn_result(state, turn_result) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec with_pending_action(t(), term() | nil) :: {:ok, t()} | {:error, Error.t()}
  def with_pending_action(%__MODULE__{} = state, pending_action) do
    with {:ok, state} <- validate(state) do
      {:ok, %__MODULE__{state | pending_action: pending_action}}
    end
  end

  @spec with_pending_action!(t(), term() | nil) :: t()
  def with_pending_action!(%__MODULE__{} = state, pending_action) do
    case with_pending_action(state, pending_action) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec clear_pending_action(t()) :: {:ok, t()} | {:error, Error.t()}
  def clear_pending_action(%__MODULE__{} = state) do
    with_pending_action(state, nil)
  end

  @spec clear_pending_action!(t()) :: t()
  def clear_pending_action!(%__MODULE__{} = state) do
    with_pending_action!(state, nil)
  end

  @spec append_messages(t(), [
          Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()
        ]) ::
          {:ok, t()} | {:error, Error.t()}
  def append_messages(%__MODULE__{} = state, messages) when is_list(messages) do
    with {:ok, conversation} <- ConversationState.append_messages(state.conversation, messages) do
      {:ok, %__MODULE__{state | conversation: conversation}}
    end
  end

  @spec append_messages!(t(), [
          Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()
        ]) ::
          t()
  def append_messages!(%__MODULE__{} = state, messages) when is_list(messages) do
    case append_messages(state, messages) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{status: :running}), do: true
  def running?(%__MODULE__{}), do: false

  @spec completed?(t()) :: boolean()
  def completed?(%__MODULE__{status: :completed}), do: true
  def completed?(%__MODULE__{}), do: false

  @spec halted?(t()) :: boolean()
  def halted?(%__MODULE__{status: :halted}), do: true
  def halted?(%__MODULE__{}), do: false

  @spec apply_turn_result(t(), RunicAI.Agent.TurnRequest.t(), TurnResult.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def apply_turn_result(%__MODULE__{} = state, turn_request, %TurnResult{} = turn_result) do
    with {:ok, state} <- validate(state),
         {:ok, turn_request} <- RunicAI.Agent.TurnRequest.validate(turn_request),
         {:ok, turn_result} <- TurnResult.validate(turn_result),
         {:ok, conversation} <-
           apply_conversation_turn(state.conversation, turn_request, turn_result) do
      next_status = next_status(state, turn_result)
      pending_action = next_pending_action(turn_result)
      metadata = update_usage_metadata(state.metadata, turn_result)

      {:ok,
       %__MODULE__{
         state
         | conversation: conversation,
           status: next_status,
           pending_action: pending_action,
           last_turn_result: turn_result,
           metadata: metadata
       }}
    end
  end

  @spec apply_turn_result!(t(), RunicAI.Agent.TurnRequest.t(), TurnResult.t()) :: t()
  def apply_turn_result!(%__MODULE__{} = state, turn_request, %TurnResult{} = turn_result) do
    case apply_turn_result(state, turn_request, turn_result) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp build_conversation(opts) do
    cond do
      conversation = Keyword.get(opts, :conversation) ->
        normalize_conversation(conversation)

      messages = Keyword.get(opts, :messages) ->
        ConversationState.new(messages)

      system = Keyword.get(opts, :system) ->
        ConversationState.new([Message.new!(:system, system)])

      true ->
        ConversationState.new()
    end
  end

  defp normalize_conversation(%ConversationState{} = conversation) do
    ConversationState.validate(conversation)
  end

  defp normalize_conversation(other) do
    {:error,
     Error.validation("agent conversation must be a Conversation.State, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp normalize_context(nil), do: {:ok, nil}

  defp normalize_context(%ContextState{} = context) do
    ContextState.validate(context)
  end

  defp normalize_context(other) do
    {:error,
     Error.validation("agent context must be a Context.State or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp normalize_last_turn_result(nil), do: {:ok, nil}

  defp normalize_last_turn_result(%TurnResult{} = turn_result) do
    TurnResult.validate(turn_result)
  end

  defp normalize_last_turn_result(other) do
    {:error,
     Error.validation("last_turn_result must be a TurnResult or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid agent status: #{inspect(status)}",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_assigns(assigns) when is_map(assigns), do: :ok

  defp validate_assigns(assigns) do
    {:error,
     Error.validation("agent assigns must be a map, got: #{inspect(assigns)}", source: __MODULE__)}
  end

  defp update_usage_metadata(metadata, %TurnResult{} = turn_result) when is_map(metadata) do
    usage = Map.get(metadata, :usage, %{})
    timing = Map.get(metadata, :timing, %{})

    llm_usage =
      case turn_result.raw do
        %{usage: usage} when is_map(usage) -> usage
        _ -> %{}
      end

    total_tokens = Map.get(usage, :total_tokens, 0) + Map.get(llm_usage, :total_tokens, 0)
    input_tokens = Map.get(usage, :input_tokens, 0) + Map.get(llm_usage, :input_tokens, 0)
    output_tokens = Map.get(usage, :output_tokens, 0) + Map.get(llm_usage, :output_tokens, 0)

    usage =
      usage
      |> Map.put(:model_calls, Map.get(usage, :model_calls, 0) + 1)
      |> Map.put(:input_tokens, input_tokens)
      |> Map.put(:output_tokens, output_tokens)
      |> Map.put(:total_tokens, total_tokens)

    timing =
      timing
      |> Map.put_new(:started_at, DateTime.utc_now())
      |> Map.put(:updated_at, DateTime.utc_now())

    metadata
    |> Map.put(:usage, usage)
    |> Map.put(:timing, timing)
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("agent metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp apply_conversation_turn(conversation, turn_request, turn_result) do
    messages_to_append =
      []
      |> maybe_append(turn_request.input_message)
      |> maybe_append(turn_result.message)

    case messages_to_append do
      [] -> {:ok, conversation}
      messages -> ConversationState.append_messages(conversation, messages)
    end
  end

  defp next_status(_state, %TurnResult{kind: :final}), do: :completed
  defp next_status(_state, %TurnResult{kind: :error}), do: :halted
  defp next_status(state, _turn_result), do: state.status

  defp next_pending_action(%TurnResult{kind: kind, details: details})
       when kind in [:wait, :handoff, :tool_requests] do
    %{kind: kind, details: details}
  end

  defp next_pending_action(_turn_result), do: nil

  defp maybe_append(messages, nil), do: messages
  defp maybe_append(messages, %Message{} = message), do: messages ++ [message]
end
