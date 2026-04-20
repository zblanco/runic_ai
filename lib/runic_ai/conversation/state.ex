defmodule RunicAI.Conversation.State do
  @moduledoc """
  Canonical state for conversation-oriented workflows.
  """

  alias RunicAI.Error
  alias RunicAI.LLM.Result
  alias RunicAI.Message

  @valid_statuses [:running, :completed, :halted]

  @enforce_keys [:messages, :turns, :status, :assigns]
  defstruct [:messages, :turns, :status, :last_assistant_message, :assigns]

  @type status :: :running | :completed | :halted

  @type t :: %__MODULE__{
          messages: [Message.t()],
          turns: non_neg_integer(),
          status: status(),
          last_assistant_message: Message.t() | nil,
          assigns: map()
        }

  @spec new([Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()], keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(messages \\ [], opts \\ []) when is_list(opts) do
    status = Keyword.get(opts, :status, :running)
    assigns = Keyword.get(opts, :assigns, %{})
    turns = Keyword.get(opts, :turns)
    last_assistant_message = Keyword.get(opts, :last_assistant_message)

    with {:ok, normalized_messages} <- Message.normalize_list(messages),
         :ok <- validate_status(status),
         :ok <- validate_assigns(assigns),
         {:ok, turns} <- validate_turns(turns || infer_turns(normalized_messages)),
         {:ok, normalized_last_assistant} <-
           normalize_last_assistant(
             last_assistant_message || find_last_assistant(normalized_messages)
           ) do
      {:ok,
       %__MODULE__{
         messages: normalized_messages,
         turns: turns,
         status: status,
         last_assistant_message: normalized_last_assistant,
         assigns: assigns
       }}
    end
  end

  @spec new!([Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()], keyword()) ::
          t()
  def new!(messages \\ [], opts \\ []) do
    case new(messages, opts) do
      {:ok, state} -> state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = state) do
    with {:ok, _messages} <- Message.normalize_list(state.messages),
         :ok <- validate_status(state.status),
         :ok <- validate_assigns(state.assigns),
         {:ok, _turns} <- validate_turns(state.turns),
         {:ok, _last_assistant} <- normalize_last_assistant(state.last_assistant_message) do
      {:ok, state}
    end
  end

  @spec append_messages(t(), [
          Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()
        ]) ::
          {:ok, t()} | {:error, Error.t()}
  def append_messages(%__MODULE__{} = state, messages) do
    with {:ok, normalized_messages} <- Message.normalize_list(messages) do
      all_messages = state.messages ++ normalized_messages
      last_assistant = find_last_assistant(normalized_messages) || state.last_assistant_message

      {:ok,
       %__MODULE__{
         state
         | messages: all_messages,
           turns: state.turns + infer_turns(normalized_messages),
           last_assistant_message: last_assistant
       }}
    end
  end

  @spec append_messages!(t(), [
          Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()
        ]) ::
          t()
  def append_messages!(%__MODULE__{} = state, messages) do
    case append_messages(state, messages) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec append_turn(t(), Message.t() | String.t(), Message.t() | String.t() | Result.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def append_turn(%__MODULE__{} = state, user, assistant) do
    with {:ok, user_message} <- normalize_turn_message(user, :user),
         {:ok, assistant_message} <- normalize_assistant(assistant) do
      append_messages(state, [user_message, assistant_message])
    end
  end

  @spec append_turn!(t(), Message.t() | String.t(), Message.t() | String.t() | Result.t()) :: t()
  def append_turn!(%__MODULE__{} = state, user, assistant) do
    case append_turn(state, user, assistant) do
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

  defp normalize_turn_message(%Message{} = message, expected_role) do
    if message.role == expected_role do
      {:ok, message}
    else
      {:error,
       Error.validation("expected a #{expected_role} message, got #{inspect(message.role)}",
         source: __MODULE__
       )}
    end
  end

  defp normalize_turn_message(text, expected_role) when is_binary(text) do
    Message.new(expected_role, text)
  end

  defp normalize_turn_message(other, expected_role) do
    {:error,
     Error.validation("expected a #{expected_role} message or string, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp normalize_assistant(%Result{message: %Message{} = message}) do
    normalize_turn_message(message, :assistant)
  end

  defp normalize_assistant(message), do: normalize_turn_message(message, :assistant)

  defp normalize_last_assistant(nil), do: {:ok, nil}

  defp normalize_last_assistant(%Message{} = message) do
    normalize_turn_message(message, :assistant)
  end

  defp normalize_last_assistant(other) do
    {:error,
     Error.validation(
       "last_assistant_message must be an assistant message or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid conversation status: #{inspect(status)}",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_assigns(assigns) when is_map(assigns), do: :ok

  defp validate_assigns(assigns) do
    {:error,
     Error.validation("conversation assigns must be a map, got: #{inspect(assigns)}",
       source: __MODULE__
     )}
  end

  defp validate_turns(turns) when is_integer(turns) and turns >= 0, do: {:ok, turns}

  defp validate_turns(turns) do
    {:error,
     Error.validation("conversation turns must be a non-negative integer, got: #{inspect(turns)}",
       source: __MODULE__
     )}
  end

  defp infer_turns(messages) do
    Enum.count(messages, &(&1.role == :assistant))
  end

  defp find_last_assistant(messages) do
    Enum.find(messages |> Enum.reverse(), &(&1.role == :assistant))
  end
end
