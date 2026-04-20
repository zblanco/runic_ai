defmodule RunicAI.Tool.CallRequest do
  @moduledoc """
  Normalized request to invoke one tool once.
  """

  alias RunicAI.Error

  @enforce_keys [:id, :tool_name, :arguments, :request_index, :metadata]
  defstruct [:id, :tool_name, :arguments, :request_index, :raw, :metadata]

  @type t :: %__MODULE__{
          id: String.t(),
          tool_name: String.t(),
          arguments: map(),
          request_index: non_neg_integer(),
          raw: term(),
          metadata: map()
        }

  @spec new(String.t(), String.t(), map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, tool_name, arguments, opts \\ []) when is_list(opts) do
    request_index = Keyword.get(opts, :request_index, 0)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_tool_name(tool_name),
         :ok <- validate_arguments(arguments),
         :ok <- validate_request_index(request_index),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         tool_name: tool_name,
         arguments: arguments,
         request_index: request_index,
         raw: Keyword.get(opts, :raw),
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t(), String.t(), map(), keyword()) :: t()
  def new!(id, tool_name, arguments, opts \\ []) do
    case new(id, tool_name, arguments, opts) do
      {:ok, call_request} -> call_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = call_request) do
    new(call_request.id, call_request.tool_name, call_request.arguments,
      request_index: call_request.request_index,
      raw: call_request.raw,
      metadata: call_request.metadata
    )
  end

  @spec from_provider(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_provider(tool_call, opts \\ []) do
    request_index = Keyword.get(opts, :request_index, 0)
    metadata = Keyword.get(opts, :metadata, %{})

    normalized = ReqLLM.ToolCall.from_map(tool_call)

    new(normalized.id, normalized.name, normalized.arguments,
      request_index: request_index,
      raw: tool_call,
      metadata: metadata
    )
  rescue
    exception ->
      {:error, Error.from_exception(exception, kind: :validation, source: __MODULE__)}
  end

  @spec from_provider!(term(), keyword()) :: t()
  def from_provider!(tool_call, opts \\ []) do
    case from_provider(tool_call, opts) do
      {:ok, call_request} -> call_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("tool call id must be a non-empty string, got: #{inspect(id)}",
       source: __MODULE__
     )}
  end

  defp validate_tool_name(tool_name) when is_binary(tool_name) and tool_name != "", do: :ok

  defp validate_tool_name(tool_name) do
    {:error,
     Error.validation("tool_name must be a non-empty string, got: #{inspect(tool_name)}",
       source: __MODULE__
     )}
  end

  defp validate_arguments(arguments) when is_map(arguments), do: :ok

  defp validate_arguments(arguments) do
    {:error,
     Error.validation("tool call arguments must be a map, got: #{inspect(arguments)}",
       source: __MODULE__
     )}
  end

  defp validate_request_index(request_index)
       when is_integer(request_index) and request_index >= 0,
       do: :ok

  defp validate_request_index(request_index) do
    {:error,
     Error.validation("tool request_index must be a non-negative integer",
       source: __MODULE__,
       details: %{request_index: request_index}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool call metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
