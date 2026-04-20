defmodule RunicAI.Tool.CallResult do
  @moduledoc """
  Normalized outcome of one tool invocation.
  """

  alias RunicAI.Error
  alias RunicAI.Tool.CallRequest

  @valid_statuses [:ok, :error, :retry, :skipped]

  @enforce_keys [:request, :status, :metadata]
  defstruct [:request, :status, :output, :error, :started_at, :completed_at, :metadata]

  @type status :: :ok | :error | :retry | :skipped

  @type t :: %__MODULE__{
          request: CallRequest.t(),
          status: status(),
          output: term(),
          error: Error.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(CallRequest.t(), status(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%CallRequest{} = request, status, opts \\ []) when is_list(opts) do
    output = Keyword.get(opts, :output)
    started_at = Keyword.get(opts, :started_at)
    completed_at = Keyword.get(opts, :completed_at)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, request} <- CallRequest.validate(request),
         :ok <- validate_status(status),
         {:ok, normalized_error} <- normalize_error(status, Keyword.get(opts, :error)),
         :ok <- validate_timestamp(started_at, :started_at),
         :ok <- validate_timestamp(completed_at, :completed_at),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         request: request,
         status: status,
         output: output,
         error: normalized_error,
         started_at: started_at,
         completed_at: completed_at,
         metadata: metadata
       }}
    end
  end

  @spec new!(CallRequest.t(), status(), keyword()) :: t()
  def new!(%CallRequest{} = request, status, opts \\ []) do
    case new(request, status, opts) do
      {:ok, call_result} -> call_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = call_result) do
    new(call_result.request, call_result.status,
      output: call_result.output,
      error: call_result.error,
      started_at: call_result.started_at,
      completed_at: call_result.completed_at,
      metadata: call_result.metadata
    )
  end

  @spec ok(CallRequest.t(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def ok(%CallRequest{} = request, output, opts \\ []) do
    new(request, :ok,
      output: output,
      started_at: Keyword.get(opts, :started_at),
      completed_at: Keyword.get(opts, :completed_at),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec ok!(CallRequest.t(), term(), keyword()) :: t()
  def ok!(%CallRequest{} = request, output, opts \\ []) do
    case ok(request, output, opts) do
      {:ok, call_result} -> call_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec error(CallRequest.t(), Error.t() | term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def error(%CallRequest{} = request, error_or_reason, opts \\ []) do
    new(request, :error,
      error: error_or_reason,
      output: Keyword.get(opts, :output),
      started_at: Keyword.get(opts, :started_at),
      completed_at: Keyword.get(opts, :completed_at),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec error!(CallRequest.t(), Error.t() | term(), keyword()) :: t()
  def error!(%CallRequest{} = request, error_or_reason, opts \\ []) do
    case error(request, error_or_reason, opts) do
      {:ok, call_result} -> call_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec retry(CallRequest.t(), Error.t() | term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def retry(%CallRequest{} = request, error_or_reason, opts \\ []) do
    new(request, :retry,
      error: error_or_reason,
      output: Keyword.get(opts, :output),
      started_at: Keyword.get(opts, :started_at),
      completed_at: Keyword.get(opts, :completed_at),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec retry!(CallRequest.t(), Error.t() | term(), keyword()) :: t()
  def retry!(%CallRequest{} = request, error_or_reason, opts \\ []) do
    case retry(request, error_or_reason, opts) do
      {:ok, call_result} -> call_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec skipped(CallRequest.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def skipped(%CallRequest{} = request, opts \\ []) do
    new(request, :skipped,
      error: Keyword.get(opts, :error),
      output: Keyword.get(opts, :output),
      started_at: Keyword.get(opts, :started_at),
      completed_at: Keyword.get(opts, :completed_at),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec skipped!(CallRequest.t(), keyword()) :: t()
  def skipped!(%CallRequest{} = request, opts \\ []) do
    case skipped(request, opts) do
      {:ok, call_result} -> call_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid tool call result status: #{inspect(status)}",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp normalize_error(:ok, nil), do: {:ok, nil}
  defp normalize_error(:ok, %Error{} = error), do: {:ok, error}
  defp normalize_error(:ok, reason), do: {:ok, Error.from_reason(reason, source: __MODULE__)}

  defp normalize_error(status, nil) when status in [:error, :retry], do: {:ok, nil}
  defp normalize_error(_status, nil), do: {:ok, nil}
  defp normalize_error(_status, %Error{} = error), do: {:ok, error}
  defp normalize_error(_status, reason), do: {:ok, Error.from_reason(reason, source: __MODULE__)}

  defp validate_timestamp(nil, _field), do: :ok
  defp validate_timestamp(%DateTime{}, _field), do: :ok

  defp validate_timestamp(timestamp, field) do
    {:error,
     Error.validation("tool call result #{field} must be a DateTime or nil",
       source: __MODULE__,
       details: %{field: field, timestamp: timestamp}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool call result metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
