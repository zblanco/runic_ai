defmodule RunicAI.LLM.Result do
  @moduledoc """
  Canonical result contract for LLM text generation.
  """

  alias RunicAI.Error
  alias RunicAI.Message

  @enforce_keys [:message]
  defstruct [:message, :finish_reason, usage: %{}, raw: nil, metadata: %{}]

  @type t :: %__MODULE__{
          message: Message.t(),
          finish_reason: atom() | String.t() | nil,
          usage: map(),
          raw: term(),
          metadata: map()
        }

  @spec new(Message.t() | ReqLLM.Message.t() | map(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(message, opts \\ []) when is_list(opts) do
    usage = Keyword.get(opts, :usage, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_message} <- Message.normalize(message),
         :ok <- validate_message_role(normalized_message),
         :ok <- validate_usage(usage),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         message: normalized_message,
         finish_reason: Keyword.get(opts, :finish_reason),
         usage: usage,
         raw: Keyword.get(opts, :raw),
         metadata: metadata
       }}
    end
  end

  @spec new!(Message.t() | ReqLLM.Message.t() | map(), keyword()) :: t()
  def new!(message, opts \\ []) do
    case new(message, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = result) do
    with {:ok, _message} <- Message.validate(result.message),
         :ok <- validate_message_role(result.message),
         :ok <- validate_usage(result.usage),
         :ok <- validate_metadata(result.metadata) do
      {:ok, result}
    end
  end

  @spec from_req_llm_response(ReqLLM.Response.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_req_llm_response(%ReqLLM.Response{} = response) do
    message =
      response.message ||
        response.context
        |> ReqLLM.Context.to_list()
        |> Enum.reverse()
        |> Enum.find(&(&1.role == :assistant))

    if is_nil(message) do
      {:error,
       Error.provider("ReqLLM response did not contain an assistant message", source: __MODULE__)}
    else
      new(message,
        finish_reason: response.finish_reason,
        usage: response.usage || %{},
        raw: response
      )
    end
  end

  @spec from_req_llm_response!(ReqLLM.Response.t()) :: t()
  def from_req_llm_response!(%ReqLLM.Response{} = response) do
    case from_req_llm_response(response) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec text(t()) :: String.t()
  def text(%__MODULE__{message: message}), do: Message.text(message)

  defp validate_message_role(%Message{role: :assistant}), do: :ok

  defp validate_message_role(%Message{role: role}) do
    {:error,
     Error.validation("LLM result message must have role :assistant, got #{inspect(role)}",
       source: __MODULE__
     )}
  end

  defp validate_usage(usage) when is_map(usage), do: :ok

  defp validate_usage(usage) do
    {:error,
     Error.validation("LLM result usage must be a map, got: #{inspect(usage)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("LLM result metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
