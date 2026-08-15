defmodule RunicAI.Trace.Trajectory do
  @moduledoc """
  Replayable trace artifact for one harness-managed session.
  """

  alias RunicAI.Error
  alias RunicAI.Trace.Event

  @valid_session_kinds [:turn_processor, :integrated]

  @enforce_keys [:id, :session_kind, :events, :metadata]
  defstruct [
    :id,
    :recipe,
    :session_kind,
    events: [],
    started_at: nil,
    completed_at: nil,
    status: nil,
    final_snapshot: nil,
    outputs: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          recipe: atom() | module() | String.t() | nil,
          session_kind: :turn_processor | :integrated,
          events: [Event.t()],
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          status: atom() | String.t() | nil,
          final_snapshot: term(),
          outputs: list(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id, default_id())
    session_kind = Keyword.get(opts, :session_kind)
    events = Keyword.get(opts, :events, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_session_kind(session_kind),
         {:ok, normalized_events} <- normalize_events(events),
         :ok <- validate_timestamp(Keyword.get(opts, :started_at), :started_at),
         :ok <- validate_timestamp(Keyword.get(opts, :completed_at), :completed_at),
         :ok <- validate_status(Keyword.get(opts, :status)),
         :ok <- validate_outputs(Keyword.get(opts, :outputs, [])),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         recipe: Keyword.get(opts, :recipe),
         session_kind: session_kind,
         events: normalized_events,
         started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
         completed_at: Keyword.get(opts, :completed_at),
         status: Keyword.get(opts, :status),
         final_snapshot: Keyword.get(opts, :final_snapshot),
         outputs: Keyword.get(opts, :outputs, []),
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, trajectory} -> trajectory
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = trajectory) do
    new(
      id: trajectory.id,
      recipe: trajectory.recipe,
      session_kind: trajectory.session_kind,
      events: trajectory.events,
      started_at: trajectory.started_at,
      completed_at: trajectory.completed_at,
      status: trajectory.status,
      final_snapshot: trajectory.final_snapshot,
      outputs: trajectory.outputs,
      metadata: trajectory.metadata
    )
  end

  @spec append_event(t(), Event.t()) :: {:ok, t()} | {:error, Error.t()}
  def append_event(%__MODULE__{} = trajectory, %Event{} = event) do
    append_events(trajectory, [event])
  end

  @spec append_event!(t(), Event.t()) :: t()
  def append_event!(%__MODULE__{} = trajectory, %Event{} = event) do
    case append_event(trajectory, event) do
      {:ok, updated_trajectory} -> updated_trajectory
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec append_events(t(), [Event.t()]) :: {:ok, t()} | {:error, Error.t()}
  def append_events(%__MODULE__{} = trajectory, events) when is_list(events) do
    with {:ok, normalized_events} <- normalize_events(events) do
      next_sequence = length(trajectory.events) + 1

      assigned_events =
        normalized_events
        |> Enum.with_index(next_sequence)
        |> Enum.map(fn {%Event{} = event, sequence} ->
          Event.assign(event, trajectory.id, sequence)
        end)

      {:ok, %__MODULE__{trajectory | events: trajectory.events ++ assigned_events}}
    end
  end

  @spec append_events!(t(), [Event.t()]) :: t()
  def append_events!(%__MODULE__{} = trajectory, events) when is_list(events) do
    case append_events(trajectory, events) do
      {:ok, updated_trajectory} -> updated_trajectory
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec record(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def record(%__MODULE__{} = trajectory, opts \\ []) when is_list(opts) do
    outputs = Keyword.get(opts, :outputs, trajectory.outputs)
    metadata = Keyword.get(opts, :metadata, trajectory.metadata)
    completed_at = Keyword.get(opts, :completed_at, DateTime.utc_now())

    with :ok <- validate_outputs(outputs),
         :ok <- validate_metadata(metadata),
         :ok <- validate_status(Keyword.get(opts, :status, trajectory.status)),
         :ok <- validate_timestamp(completed_at, :completed_at) do
      {:ok,
       %__MODULE__{
         trajectory
         | status: Keyword.get(opts, :status, trajectory.status),
           final_snapshot: Keyword.get(opts, :final_snapshot, trajectory.final_snapshot),
           outputs: outputs,
           completed_at: completed_at,
           metadata: metadata
       }}
    end
  end

  @spec record!(t(), keyword()) :: t()
  def record!(%__MODULE__{} = trajectory, opts \\ []) do
    case record(trajectory, opts) do
      {:ok, updated_trajectory} -> updated_trajectory
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec events_of_kind(t(), atom() | String.t()) :: [Event.t()]
  def events_of_kind(%__MODULE__{} = trajectory, kind) when is_binary(kind) do
    events_of_kind(trajectory, String.to_atom(kind))
  end

  def events_of_kind(%__MODULE__{events: events}, kind) when is_atom(kind) do
    Enum.filter(events, &(&1.kind == kind))
  end

  @spec count_events(t(), atom() | String.t()) :: non_neg_integer()
  def count_events(%__MODULE__{} = trajectory, kind) do
    trajectory
    |> events_of_kind(kind)
    |> length()
  end

  defp normalize_events(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn
      %Event{} = event, {:ok, acc} ->
        case Event.validate(event) do
          {:ok, normalized_event} -> {:cont, {:ok, [normalized_event | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      other, _acc ->
        {:halt,
         {:error,
          Error.validation("trajectory events must be Trace.Event values",
            source: __MODULE__,
            details: %{event: other}
          )}}
    end)
    |> case do
      {:ok, normalized_events} -> {:ok, Enum.reverse(normalized_events)}
      error -> error
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("trajectory id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_session_kind(session_kind) when session_kind in @valid_session_kinds, do: :ok

  defp validate_session_kind(session_kind) do
    {:error,
     Error.validation("invalid trajectory session_kind",
       source: __MODULE__,
       details: %{session_kind: session_kind, valid_session_kinds: @valid_session_kinds}
     )}
  end

  defp validate_status(nil), do: :ok
  defp validate_status(status) when is_atom(status) or is_binary(status), do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("trajectory status must be an atom, string, or nil",
       source: __MODULE__,
       details: %{status: status}
     )}
  end

  defp validate_timestamp(nil, _field), do: :ok
  defp validate_timestamp(%DateTime{}, _field), do: :ok

  defp validate_timestamp(value, field) do
    {:error,
     Error.validation("trajectory #{field} must be a DateTime or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_outputs(outputs) when is_list(outputs), do: :ok

  defp validate_outputs(outputs) do
    {:error,
     Error.validation("trajectory outputs must be a list",
       source: __MODULE__,
       details: %{outputs: outputs}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("trajectory metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp default_id, do: "trace:#{System.unique_integer([:positive])}"
end
