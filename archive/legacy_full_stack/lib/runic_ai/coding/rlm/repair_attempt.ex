defmodule RunicAI.Coding.RLM.RepairAttempt do
  @moduledoc """
  Evidence captured for one bounded repair attempt.

  A repair attempt may complete, fail, or time out. In all cases it can still
  leave useful workspace changes behind, so the parent loop records the delta
  and subsequent verification evidence before deciding the next action.
  """

  alias RunicAI.Coding.RLM.ChildResult
  alias RunicAI.Error

  @statuses [:completed, :partial, :timeout, :failed]

  @enforce_keys [
    :id,
    :iteration,
    :status,
    :workspace_root,
    :started_at,
    :completed_at,
    :changed_files,
    :delta,
    :child_result,
    :error,
    :metadata
  ]
  defstruct [
    :id,
    :iteration,
    :status,
    :workspace_root,
    :started_at,
    :completed_at,
    changed_files: [],
    delta: %{},
    child_result: nil,
    error: nil,
    metadata: %{}
  ]

  @type status :: :completed | :partial | :timeout | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          iteration: pos_integer(),
          status: status(),
          workspace_root: Path.t(),
          started_at: DateTime.t(),
          completed_at: DateTime.t(),
          changed_files: [Path.t()],
          delta: map(),
          child_result: ChildResult.t() | nil,
          error: Error.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    attempt = %__MODULE__{
      id: Keyword.get(opts, :id) || "repair-attempt:#{Keyword.fetch!(opts, :iteration)}",
      iteration: Keyword.fetch!(opts, :iteration),
      status: Keyword.fetch!(opts, :status),
      workspace_root: Keyword.fetch!(opts, :workspace_root),
      started_at: Keyword.fetch!(opts, :started_at),
      completed_at: Keyword.fetch!(opts, :completed_at),
      changed_files: Keyword.get(opts, :changed_files, []),
      delta: Keyword.get(opts, :delta, %{}),
      child_result: Keyword.get(opts, :child_result),
      error: Keyword.get(opts, :error),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(attempt)
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, attempt} -> attempt
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = attempt) do
    with :ok <- non_empty_string(attempt.id, :id),
         :ok <- positive_integer(attempt.iteration, :iteration),
         :ok <- status(attempt.status),
         :ok <- non_empty_string(attempt.workspace_root, :workspace_root),
         :ok <- datetime(attempt.started_at, :started_at),
         :ok <- datetime(attempt.completed_at, :completed_at),
         :ok <- string_list(attempt.changed_files, :changed_files),
         :ok <- map(attempt.delta, :delta),
         :ok <- optional_child_result(attempt.child_result),
         :ok <- optional_error(attempt.error),
         :ok <- map(attempt.metadata, :metadata) do
      {:ok, attempt}
    end
  end

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("repair attempt #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp positive_integer(value, field) do
    {:error,
     Error.validation("repair attempt #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp status(value) when value in @statuses, do: :ok

  defp status(value) do
    {:error,
     Error.validation("invalid repair attempt status",
       source: __MODULE__,
       details: %{status: value, valid_statuses: @statuses}
     )}
  end

  defp datetime(%DateTime{}, _field), do: :ok

  defp datetime(value, field) do
    {:error,
     Error.validation("repair attempt #{field} must be a DateTime",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp string_list(values, _field) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: :ok, else: {:error, list_error(values)}
  end

  defp string_list(value, field) do
    {:error,
     Error.validation("repair attempt #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp list_error(values) do
    Error.validation("repair attempt changed_files must contain strings",
      source: __MODULE__,
      details: %{values: values}
    )
  end

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field) do
    {:error,
     Error.validation("repair attempt #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp optional_child_result(nil), do: :ok

  defp optional_child_result(%ChildResult{} = child) do
    case ChildResult.validate(child) do
      {:ok, _child} -> :ok
      error -> error
    end
  end

  defp optional_child_result(child) do
    {:error,
     Error.validation("repair attempt child_result must be a ChildResult or nil",
       source: __MODULE__,
       details: %{child_result: child}
     )}
  end

  defp optional_error(nil), do: :ok
  defp optional_error(%Error{}), do: :ok

  defp optional_error(error) do
    {:error,
     Error.validation("repair attempt error must be a RunicAI.Error or nil",
       source: __MODULE__,
       details: %{error: error}
     )}
  end
end
