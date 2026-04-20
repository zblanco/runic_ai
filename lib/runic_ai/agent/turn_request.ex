defmodule RunicAI.Agent.TurnRequest do
  @moduledoc """
  Canonical input contract for one conversational turn.
  """

  alias RunicAI.Agent.State
  alias RunicAI.Error
  alias RunicAI.LLM.Request, as: LLMRequest
  alias RunicAI.Message
  alias RunicAI.Prompt

  @request_keys [
    :state,
    :input_message,
    :user,
    :history_window,
    :pinned_messages,
    :observations,
    :model,
    :llm_opts,
    :metadata
  ]

  @state_assembly_keys [:system, :messages, :assigns, :state_metadata]
  @control_input_keys [:runtime, :review_decision, :resume_signal, :control]
  @reserved_input_keys @request_keys ++ @state_assembly_keys ++ @control_input_keys

  @enforce_keys [
    :state,
    :history_window,
    :pinned_messages,
    :observations,
    :model,
    :llm_opts,
    :metadata
  ]
  defstruct [
    :state,
    :input_message,
    :history_window,
    :pinned_messages,
    :observations,
    :model,
    :llm_opts,
    :metadata
  ]

  @type history_window :: :all | non_neg_integer()

  @type t :: %__MODULE__{
          state: State.t(),
          input_message: Message.t() | nil,
          history_window: history_window(),
          pinned_messages: [Message.t()],
          observations: [Message.t()],
          model: String.t() | {atom(), String.t()} | map(),
          llm_opts: keyword(),
          metadata: map()
        }

  @spec new(State.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%State{} = state, opts \\ []) when is_list(opts) do
    input_message = normalize_input_message(Keyword.get(opts, :input_message))
    pinned_messages = Keyword.get(opts, :pinned_messages, [])
    observations = Keyword.get(opts, :observations, [])
    history_window = Keyword.get(opts, :history_window, :all)
    model = Keyword.get(opts, :model)
    llm_opts = extract_llm_opts(opts)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, state} <- State.validate(state),
         {:ok, input_message} <- input_message,
         {:ok, pinned_messages} <- Message.normalize_list(pinned_messages),
         {:ok, observations} <- Message.normalize_list(observations),
         :ok <- validate_history_window(history_window),
         :ok <- validate_model(model),
         :ok <- validate_llm_opts(llm_opts),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         state: state,
         input_message: input_message,
         history_window: history_window,
         pinned_messages: pinned_messages,
         observations: observations,
         model: model,
         llm_opts: llm_opts,
         metadata: metadata
       }}
    end
  end

  @spec new!(State.t(), keyword()) :: t()
  def new!(%State{} = state, opts \\ []) do
    case new(state, opts) do
      {:ok, turn_request} -> turn_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = turn_request) do
    new(turn_request.state,
      input_message: turn_request.input_message,
      history_window: turn_request.history_window,
      pinned_messages: turn_request.pinned_messages,
      observations: turn_request.observations,
      model: turn_request.model,
      llm_opts: turn_request.llm_opts,
      metadata: turn_request.metadata
    )
  end

  @spec with_state(t(), State.t()) :: {:ok, t()} | {:error, Error.t()}
  def with_state(%__MODULE__{} = turn_request, %State{} = state) do
    with {:ok, state} <- State.validate(state) do
      {:ok, %__MODULE__{turn_request | state: state}}
    end
  end

  @spec with_state!(t(), State.t()) :: t()
  def with_state!(%__MODULE__{} = turn_request, %State{} = state) do
    case with_state(turn_request, state) do
      {:ok, updated_turn_request} -> updated_turn_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | State.t() | map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = turn_request, _defaults), do: validate(turn_request)

  def from_input(%State{} = state, defaults) when is_list(defaults) do
    new(state, defaults)
  end

  def from_input(input, defaults) when is_map(input) and is_list(defaults) do
    with {:ok, state} <- resolve_state(input, defaults) do
      input_message = Map.get(input, :input_message) || Map.get(input, :user)

      new(state,
        input_message: input_message,
        history_window:
          Map.get(input, :history_window, Keyword.get(defaults, :history_window, :all)),
        pinned_messages:
          Map.get(input, :pinned_messages, Keyword.get(defaults, :pinned_messages, [])),
        observations: Map.get(input, :observations, Keyword.get(defaults, :observations, [])),
        model: Map.get(input, :model, Keyword.get(defaults, :model)),
        llm_opts: merge_llm_opts(extract_llm_opts(defaults), extract_llm_opts(input)),
        metadata: Map.merge(Keyword.get(defaults, :metadata, %{}), Map.get(input, :metadata, %{}))
      )
    end
  end

  def from_input(other, _defaults) do
    {:error,
     Error.validation("expected an Agent.TurnRequest-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | State.t() | map(), keyword()) :: t()
  def from_input!(input, defaults \\ []) do
    case from_input(input, defaults) do
      {:ok, turn_request} -> turn_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec history_messages(t()) :: [Message.t()]
  def history_messages(%__MODULE__{} = turn_request) do
    messages = turn_request.state.conversation.messages
    {system_prefix, remaining_messages} = Enum.split_while(messages, &(&1.role == :system))

    case turn_request.history_window do
      :all -> messages
      0 -> system_prefix
      count when is_integer(count) -> system_prefix ++ Enum.take(remaining_messages, -count)
    end
  end

  @spec prompt_messages(t()) :: [Message.t()]
  def prompt_messages(%__MODULE__{} = turn_request) do
    turn_request.pinned_messages ++
      history_messages(turn_request) ++
      maybe_wrap(turn_request.input_message) ++ turn_request.observations
  end

  @spec to_prompt(t()) :: {:ok, Prompt.t()} | {:error, Error.t()}
  def to_prompt(%__MODULE__{} = turn_request) do
    Prompt.new(prompt_messages(turn_request), metadata: turn_request.metadata)
  end

  @spec to_llm_request(t(), Prompt.t()) :: {:ok, LLMRequest.t()} | {:error, Error.t()}
  def to_llm_request(%__MODULE__{} = turn_request, %Prompt{} = prompt) do
    LLMRequest.new(turn_request.model, prompt,
      opts: turn_request.llm_opts,
      metadata: turn_request.metadata
    )
  end

  defp resolve_state(input, defaults) do
    case Map.get(input, :state) || Keyword.get(defaults, :state) do
      %State{} = state ->
        State.validate(state)

      nil ->
        defaults
        |> default_state_opts(input)
        |> case do
          nil ->
            State.new()

          state_opts ->
            State.new(state_opts)
        end

      other ->
        {:error,
         Error.validation(
           "Agent turn request state must be an Agent.State, got: #{inspect(other)}",
           source: __MODULE__
         )}
    end
  end

  defp default_state_opts(defaults, input) do
    system = Map.get(input, :system, Keyword.get(defaults, :system))
    messages = Map.get(input, :messages, Keyword.get(defaults, :messages))
    assigns = Map.get(input, :assigns, Keyword.get(defaults, :assigns, %{}))
    metadata = Map.get(input, :state_metadata, Keyword.get(defaults, :state_metadata, %{}))

    cond do
      is_list(messages) -> [messages: messages, assigns: assigns, metadata: metadata]
      is_binary(system) -> [system: system, assigns: assigns, metadata: metadata]
      true -> nil
    end
  end

  defp normalize_input_message(nil), do: {:ok, nil}

  defp normalize_input_message(%Message{} = message) do
    if message.role == :user do
      {:ok, message}
    else
      {:error,
       Error.validation("turn input_message must have role :user, got #{inspect(message.role)}",
         source: __MODULE__
       )}
    end
  end

  defp normalize_input_message(%ReqLLM.Message{} = message) do
    with {:ok, normalized} <- Message.from_req_llm(message) do
      normalize_input_message(normalized)
    end
  end

  defp normalize_input_message(text) when is_binary(text), do: Message.new(:user, text)

  defp normalize_input_message(other) do
    {:error,
     Error.validation(
       "turn input_message must be a user message, string, or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp validate_history_window(:all), do: :ok
  defp validate_history_window(window) when is_integer(window) and window >= 0, do: :ok

  defp validate_history_window(window) do
    {:error,
     Error.validation(
       "history_window must be :all or a non-negative integer, got: #{inspect(window)}",
       source: __MODULE__
     )}
  end

  defp validate_model(model) when is_binary(model), do: :ok
  defp validate_model({provider, model}) when is_atom(provider) and is_binary(model), do: :ok
  defp validate_model(model) when is_map(model), do: :ok

  defp validate_model(model) do
    {:error,
     Error.validation("invalid turn model specification: #{inspect(model)}", source: __MODULE__)}
  end

  defp validate_llm_opts(opts) when is_list(opts), do: :ok

  defp validate_llm_opts(opts) do
    {:error,
     Error.validation("turn llm_opts must be a keyword list, got: #{inspect(opts)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("turn metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp extract_llm_opts(opts) when is_list(opts) do
    {nested_opts, rest} = Keyword.pop(opts, :llm_opts, [])
    nested_opts ++ Keyword.drop(rest, @reserved_input_keys)
  end

  defp extract_llm_opts(input) when is_map(input) do
    nested_opts = Map.get(input, :llm_opts, [])

    input
    |> Map.drop(@reserved_input_keys)
    |> Enum.into([])
    |> Kernel.++(nested_opts)
    |> Enum.reverse()
    |> Enum.reduce([], fn {key, value}, acc -> Keyword.put(acc, key, value) end)
  end

  defp merge_llm_opts(defaults, overrides), do: Keyword.merge(defaults, overrides)

  defp maybe_wrap(nil), do: []
  defp maybe_wrap(value), do: [value]
end
