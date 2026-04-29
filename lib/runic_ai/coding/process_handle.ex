defmodule RunicAI.Coding.ProcessHandle do
  @moduledoc """
  Handle for a background process managed by `RunicAI.Coding.ProcessRegistry`.
  """

  alias RunicAI.Error

  @valid_statuses [:running, :exited, :killed, :blocked]

  @enforce_keys [:id, :command, :cwd, :status, :metadata]
  defstruct [
    :id,
    :command,
    :argv,
    :cwd,
    :status,
    :exit_status,
    :started_at,
    :updated_at,
    metadata: %{}
  ]

  @type status :: :running | :exited | :killed | :blocked

  @type t :: %__MODULE__{
          id: String.t(),
          command: String.t(),
          argv: [String.t()] | nil,
          cwd: Path.t(),
          status: status(),
          exit_status: non_neg_integer() | nil,
          started_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    id = Keyword.get(opts, :id)
    command = Keyword.get(opts, :command)
    argv = Keyword.get(opts, :argv)
    cwd = Keyword.get(opts, :cwd)
    status = Keyword.get(opts, :status, :running)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_string(id, :id),
         :ok <- validate_string(command, :command),
         :ok <- validate_optional_argv(argv),
         :ok <- validate_string(cwd, :cwd),
         :ok <- validate_status(status),
         :ok <- validate_optional_non_neg_integer(Keyword.get(opts, :exit_status), :exit_status),
         :ok <- validate_optional_datetime(Keyword.get(opts, :started_at), :started_at),
         :ok <- validate_optional_datetime(Keyword.get(opts, :updated_at), :updated_at),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         command: command,
         argv: argv,
         cwd: cwd,
         status: status,
         exit_status: Keyword.get(opts, :exit_status),
         started_at: Keyword.get(opts, :started_at),
         updated_at: Keyword.get(opts, :updated_at),
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, handle} -> handle
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec update(t(), keyword()) :: t()
  def update(%__MODULE__{} = handle, opts) when is_list(opts) do
    new!(
      id: handle.id,
      command: handle.command,
      argv: handle.argv,
      cwd: handle.cwd,
      status: Keyword.get(opts, :status, handle.status),
      exit_status: Keyword.get(opts, :exit_status, handle.exit_status),
      started_at: handle.started_at,
      updated_at: Keyword.get(opts, :updated_at, DateTime.utc_now()),
      metadata: Map.merge(handle.metadata, Keyword.get(opts, :metadata, %{}))
    )
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid process handle status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("process handle #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_argv(nil), do: :ok

  defp validate_optional_argv(argv) when is_list(argv) do
    if Enum.all?(argv, &is_binary/1), do: :ok, else: invalid_argv(argv)
  end

  defp validate_optional_argv(argv), do: invalid_argv(argv)

  defp invalid_argv(argv) do
    {:error,
     Error.validation("process handle argv must be a list of strings or nil",
       source: __MODULE__,
       details: %{argv: argv}
     )}
  end

  defp validate_optional_non_neg_integer(nil, _field), do: :ok

  defp validate_optional_non_neg_integer(value, _field) when is_integer(value) and value >= 0,
    do: :ok

  defp validate_optional_non_neg_integer(value, field) do
    {:error,
     Error.validation("process handle #{field} must be a non-negative integer or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_datetime(nil, _field), do: :ok
  defp validate_optional_datetime(%DateTime{}, _field), do: :ok

  defp validate_optional_datetime(value, field) do
    {:error,
     Error.validation("process handle #{field} must be a DateTime or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("process handle metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
