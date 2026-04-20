defmodule RunicAI.Agent.TurnResult do
  @moduledoc """
  Typed interpretation of one generated turn.
  """

  alias RunicAI.Error
  alias RunicAI.LLM.Result, as: LLMResult
  alias RunicAI.Message
  alias RunicAI.Wait

  @valid_kinds [:reply, :final, :wait, :handoff, :tool_requests, :error]

  @enforce_keys [:kind]
  defstruct [:kind, :message, details: %{}, raw: nil, metadata: %{}]

  @type kind :: :reply | :final | :wait | :handoff | :tool_requests | :error

  @type t :: %__MODULE__{
          kind: kind(),
          message: Message.t() | nil,
          details: map(),
          raw: term(),
          metadata: map()
        }

  @spec new(kind(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, opts \\ []) when is_list(opts) do
    message = Keyword.get(opts, :message)
    details = Keyword.get(opts, :details, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_kind(kind),
         {:ok, message} <- normalize_message(message),
         :ok <- validate_message_requirement(kind, message),
         :ok <- validate_details(details),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         kind: kind,
         message: message,
         details: details,
         raw: Keyword.get(opts, :raw),
         metadata: metadata
       }}
    end
  end

  @spec new!(kind(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, turn_result} -> turn_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = turn_result) do
    new(turn_result.kind,
      message: turn_result.message,
      details: turn_result.details,
      raw: turn_result.raw,
      metadata: turn_result.metadata
    )
  end

  @spec reply(Message.t() | ReqLLM.Message.t() | LLMResult.t() | String.t(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def reply(message, opts \\ []) do
    build_from_message(:reply, message, opts)
  end

  @spec reply!(Message.t() | ReqLLM.Message.t() | LLMResult.t() | String.t(), keyword()) :: t()
  def reply!(message, opts \\ []) do
    case reply(message, opts) do
      {:ok, turn_result} -> turn_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec final(Message.t() | ReqLLM.Message.t() | LLMResult.t() | String.t(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def final(message, opts \\ []) do
    build_from_message(:final, message, opts)
  end

  @spec final!(Message.t() | ReqLLM.Message.t() | LLMResult.t() | String.t(), keyword()) :: t()
  def final!(message, opts \\ []) do
    case final(message, opts) do
      {:ok, turn_result} -> turn_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec tool_requests(
          Message.t() | ReqLLM.Message.t() | LLMResult.t() | String.t() | nil,
          keyword()
        ) ::
          {:ok, t()} | {:error, Error.t()}
  def tool_requests(message \\ nil, opts \\ []) do
    new(:tool_requests,
      message: message,
      details: Keyword.get(opts, :details, %{}),
      raw: Keyword.get(opts, :raw),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec tool_requests!(
          Message.t() | ReqLLM.Message.t() | LLMResult.t() | String.t() | nil,
          keyword()
        ) ::
          t()
  def tool_requests!(message \\ nil, opts \\ []) do
    case tool_requests(message, opts) do
      {:ok, turn_result} -> turn_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec error(Error.t() | term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def error(error_or_reason, opts \\ [])

  def error(%Error{} = error, opts) do
    new(:error,
      details: Map.put(Keyword.get(opts, :details, %{}), :error, error),
      raw: Keyword.get(opts, :raw, error),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def error(reason, opts) do
    error =
      Error.from_reason(reason,
        kind: Keyword.get(opts, :kind, :unexpected),
        source: __MODULE__
      )

    error(error, opts)
  end

  @spec error!(Error.t() | term(), keyword()) :: t()
  def error!(error, opts \\ []) do
    case error(error, opts) do
      {:ok, turn_result} -> turn_result
      {:error, reason} -> raise ArgumentError, reason.message
    end
  end

  @spec wait(Wait.t() | map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def wait(wait_or_details, opts \\ [])

  def wait(%Wait{} = wait, opts) do
    new(:wait,
      details: Map.put(Keyword.get(opts, :details, %{}), :wait, wait),
      raw: Keyword.get(opts, :raw, wait),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def wait(details, opts) when is_map(details) do
    new(:wait,
      details: details,
      raw: Keyword.get(opts, :raw),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{kind: kind}), do: kind in [:final, :error]

  @spec tool_requests?(t()) :: boolean()
  def tool_requests?(%__MODULE__{kind: :tool_requests}), do: true
  def tool_requests?(%__MODULE__{}), do: false

  defp build_from_message(kind, %LLMResult{} = llm_result, opts) do
    new(kind,
      message: llm_result.message,
      details: Keyword.get(opts, :details, %{}),
      raw: Keyword.get(opts, :raw, llm_result),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp build_from_message(kind, message, opts) do
    new(kind,
      message: message,
      details: Keyword.get(opts, :details, %{}),
      raw: Keyword.get(opts, :raw),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp normalize_message(nil), do: {:ok, nil}

  defp normalize_message(%LLMResult{message: %Message{} = message}) do
    normalize_message(message)
  end

  defp normalize_message(%Message{} = message), do: Message.validate(message)
  defp normalize_message(%ReqLLM.Message{} = message), do: Message.from_req_llm(message)

  defp normalize_message(text) when is_binary(text) do
    Message.new(:assistant, text)
  end

  defp normalize_message(other) do
    {:error,
     Error.validation(
       "turn result message must be an assistant message, string, or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid turn result kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_message_requirement(kind, %Message{role: :assistant})
       when kind in [:reply, :final],
       do: :ok

  defp validate_message_requirement(kind, nil)
       when kind in [:wait, :handoff, :tool_requests, :error],
       do: :ok

  defp validate_message_requirement(kind, nil) when kind in [:reply, :final] do
    {:error,
     Error.validation("turn result #{kind} requires an assistant message", source: __MODULE__)}
  end

  defp validate_message_requirement(kind, %Message{} = message)
       when kind in [:wait, :handoff, :tool_requests, :error] do
    if message.role == :assistant do
      :ok
    else
      {:error,
       Error.validation("turn result message must have role :assistant", source: __MODULE__)}
    end
  end

  defp validate_details(details) when is_map(details), do: :ok

  defp validate_details(details) do
    {:error,
     Error.validation("turn result details must be a map, got: #{inspect(details)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("turn result metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
