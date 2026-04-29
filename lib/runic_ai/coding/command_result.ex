defmodule RunicAI.Coding.CommandResult do
  @moduledoc """
  Normalized result of a bounded local command invocation.
  """

  alias RunicAI.Coding.Command
  alias RunicAI.Error

  @valid_statuses [:pass, :fail, :timeout, :killed, :blocked]

  @enforce_keys [
    :status,
    :command,
    :cwd,
    :output,
    :output_preview,
    :output_bytes,
    :truncated?,
    :diagnostics,
    :metadata
  ]
  defstruct [
    :status,
    :command,
    :argv,
    :cwd,
    :exit_status,
    :output,
    :output_preview,
    :output_bytes,
    :duration_ms,
    :started_at,
    :completed_at,
    :artifact_ref,
    truncated?: false,
    diagnostics: [],
    metadata: %{}
  ]

  @type status :: :pass | :fail | :timeout | :killed | :blocked

  @type t :: %__MODULE__{
          status: status(),
          command: String.t(),
          argv: [String.t()] | nil,
          cwd: Path.t(),
          exit_status: non_neg_integer() | nil,
          output: binary(),
          output_preview: binary(),
          output_bytes: non_neg_integer(),
          duration_ms: non_neg_integer() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          artifact_ref: String.t() | nil,
          truncated?: boolean(),
          diagnostics: [map()],
          metadata: map()
        }

  @spec new(status(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(status, opts) when is_list(opts) do
    command = Keyword.get(opts, :command)
    argv = Keyword.get(opts, :argv)
    cwd = Keyword.get(opts, :cwd)
    output = Keyword.get(opts, :output, "")
    output_preview = Keyword.get(opts, :output_preview, output)
    output_bytes = Keyword.get(opts, :output_bytes, byte_size(output))
    truncated? = Keyword.get(opts, :truncated?, false)
    diagnostics = Keyword.get(opts, :diagnostics, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_status(status),
         :ok <- validate_string(command, :command),
         :ok <- validate_optional_argv(argv),
         :ok <- validate_string(cwd, :cwd),
         :ok <- validate_optional_non_neg_integer(Keyword.get(opts, :exit_status), :exit_status),
         :ok <- validate_binary(output, :output),
         :ok <- validate_binary(output_preview, :output_preview),
         :ok <- validate_non_neg_integer(output_bytes, :output_bytes),
         :ok <- validate_optional_non_neg_integer(Keyword.get(opts, :duration_ms), :duration_ms),
         :ok <- validate_optional_datetime(Keyword.get(opts, :started_at), :started_at),
         :ok <- validate_optional_datetime(Keyword.get(opts, :completed_at), :completed_at),
         :ok <- validate_optional_string(Keyword.get(opts, :artifact_ref), :artifact_ref),
         :ok <- validate_boolean(truncated?, :truncated?),
         :ok <- validate_list(diagnostics, :diagnostics),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         status: status,
         command: command,
         argv: argv,
         cwd: cwd,
         exit_status: Keyword.get(opts, :exit_status),
         output: output,
         output_preview: output_preview,
         output_bytes: output_bytes,
         duration_ms: Keyword.get(opts, :duration_ms),
         started_at: Keyword.get(opts, :started_at),
         completed_at: Keyword.get(opts, :completed_at),
         artifact_ref: Keyword.get(opts, :artifact_ref),
         truncated?: truncated?,
         diagnostics: diagnostics,
         metadata: metadata
       }}
    end
  end

  @spec new!(status(), keyword()) :: t()
  def new!(status, opts) do
    case new(status, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec blocked(Command.t() | nil, Error.t(), keyword()) :: t()
  def blocked(command, %Error{} = error, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, (command && command.cwd) || ".")

    new!(:blocked,
      command: command_display(command),
      argv: command && command.argv,
      cwd: cwd,
      output: "",
      output_preview: "",
      output_bytes: 0,
      diagnostics: [%{message: error.message, details: error.details}],
      metadata: %{error_kind: error.kind}
    )
  end

  defp command_display(nil), do: ""
  defp command_display(%Command{} = command), do: Command.display(command)

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid command result status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_string(value, _field) when is_binary(value), do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("command result #{field} must be a string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_string(nil, _field), do: :ok
  defp validate_optional_string(value, field), do: validate_string(value, field)

  defp validate_optional_argv(nil), do: :ok

  defp validate_optional_argv(argv) when is_list(argv) do
    if Enum.all?(argv, &is_binary/1) do
      :ok
    else
      invalid_argv(argv)
    end
  end

  defp validate_optional_argv(argv), do: invalid_argv(argv)

  defp invalid_argv(argv) do
    {:error,
     Error.validation("command result argv must be a list of strings or nil",
       source: __MODULE__,
       details: %{argv: argv}
     )}
  end

  defp validate_binary(value, _field) when is_binary(value), do: :ok

  defp validate_binary(value, field) do
    {:error,
     Error.validation("command result #{field} must be a binary",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_non_neg_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_neg_integer(value, field) do
    {:error,
     Error.validation("command result #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_non_neg_integer(nil, _field), do: :ok
  defp validate_optional_non_neg_integer(value, field), do: validate_non_neg_integer(value, field)

  defp validate_optional_datetime(nil, _field), do: :ok
  defp validate_optional_datetime(%DateTime{}, _field), do: :ok

  defp validate_optional_datetime(value, field) do
    {:error,
     Error.validation("command result #{field} must be a DateTime or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("command result #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("command result #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("command result #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
