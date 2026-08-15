defmodule RunicAI.Tool.Observation do
  @moduledoc """
  Normalized model-ready observation derived from a tool call result.
  """

  alias RunicAI.Error
  alias RunicAI.Message
  alias RunicAI.Tool.CallResult

  @enforce_keys [:call_id, :tool_name, :message, :metadata]
  defstruct [:call_id, :tool_name, :message, :result, :metadata]

  @type t :: %__MODULE__{
          call_id: String.t(),
          tool_name: String.t(),
          message: Message.t(),
          result: CallResult.t() | nil,
          metadata: map()
        }

  @spec new(String.t(), String.t(), Message.t() | ReqLLM.Message.t() | map(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(call_id, tool_name, message, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    result = Keyword.get(opts, :result)

    with :ok <- validate_call_id(call_id),
         :ok <- validate_tool_name(tool_name),
         {:ok, message} <- Message.normalize(message),
         :ok <- validate_message_role(message),
         {:ok, normalized_result} <- normalize_result(result),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         call_id: call_id,
         tool_name: tool_name,
         message: message,
         result: normalized_result,
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t(), String.t(), Message.t() | ReqLLM.Message.t() | map(), keyword()) :: t()
  def new!(call_id, tool_name, message, opts \\ []) do
    case new(call_id, tool_name, message, opts) do
      {:ok, observation} -> observation
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = observation) do
    new(observation.call_id, observation.tool_name, observation.message,
      result: observation.result,
      metadata: observation.metadata
    )
  end

  @spec from_call_result(CallResult.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_call_result(%CallResult{} = call_result, opts \\ []) do
    payload = observation_payload(call_result)

    tool_message =
      ReqLLM.Context.tool_result(
        call_result.request.id,
        call_result.request.tool_name,
        payload
      )

    new(call_result.request.id, call_result.request.tool_name, tool_message,
      result: call_result,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec from_call_result!(CallResult.t(), keyword()) :: t()
  def from_call_result!(%CallResult{} = call_result, opts \\ []) do
    case from_call_result(call_result, opts) do
      {:ok, observation} -> observation
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec messages([t()]) :: [Message.t()]
  def messages(observations) when is_list(observations) do
    Enum.map(observations, & &1.message)
  end

  defp observation_payload(%CallResult{status: :ok, output: output}) do
    %{ok: true, result: output}
  end

  defp observation_payload(%CallResult{status: status, error: error}) do
    %{
      ok: false,
      status: status,
      error: %{
        kind: error_kind(error),
        message: error_message(error)
      }
    }
  end

  defp validate_call_id(call_id) when is_binary(call_id) and call_id != "", do: :ok

  defp validate_call_id(call_id) do
    {:error,
     Error.validation("tool observation call_id must be a non-empty string",
       source: __MODULE__,
       details: %{call_id: call_id}
     )}
  end

  defp validate_tool_name(tool_name) when is_binary(tool_name) and tool_name != "", do: :ok

  defp validate_tool_name(tool_name) do
    {:error,
     Error.validation("tool observation tool_name must be a non-empty string",
       source: __MODULE__,
       details: %{tool_name: tool_name}
     )}
  end

  defp validate_message_role(%Message{role: :tool}), do: :ok

  defp validate_message_role(%Message{role: role}) do
    {:error,
     Error.validation("tool observation message must have role :tool, got #{inspect(role)}",
       source: __MODULE__
     )}
  end

  defp normalize_result(nil), do: {:ok, nil}
  defp normalize_result(%CallResult{} = result), do: CallResult.validate(result)

  defp normalize_result(other) do
    {:error,
     Error.validation("tool observation result must be a Tool.CallResult or nil",
       source: __MODULE__,
       details: %{result: other}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool observation metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp error_kind(%Error{kind: kind}), do: kind
  defp error_kind(_), do: :unexpected

  defp error_message(%Error{message: message}), do: message
  defp error_message(_), do: "tool execution failed"
end
