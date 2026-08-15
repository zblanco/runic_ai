defmodule RunicAI.Harness.Session do
  @moduledoc """
  Serializable-in-practice session artifact used by the harness drivers.
  """

  alias RunicAI.Error
  alias RunicAI.Trace.Sink
  alias RunicAI.Trace.Trajectory

  @valid_kinds [:turn_processor, :integrated]
  @valid_statuses [:idle, :queued, :running, :waiting, :review, :completed, :error]

  @enforce_keys [:id, :kind, :recipe, :driver, :queue, :outputs, :trajectory, :metadata]
  defstruct [
    :id,
    :kind,
    :recipe,
    :driver,
    :snapshot,
    status: :idle,
    queue: [],
    outputs: [],
    trajectory: nil,
    measurements: %{},
    metadata: %{},
    trace_sinks: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: :turn_processor | :integrated,
          recipe: module(),
          driver: module(),
          snapshot: term(),
          status: atom(),
          queue: [term()],
          outputs: [term()],
          trajectory: Trajectory.t(),
          measurements: map(),
          metadata: map(),
          trace_sinks: [Sink.normalized_sink()]
        }

  @spec new(:turn_processor | :integrated, module(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(kind, recipe, opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id) || default_id(kind)
    queue = Keyword.get(opts, :queue, [])
    outputs = Keyword.get(opts, :outputs, [])
    metadata = Keyword.get(opts, :metadata, %{})
    measurements = Keyword.get(opts, :measurements, %{})

    with :ok <- validate_kind(kind),
         :ok <- validate_recipe(recipe),
         :ok <- validate_driver(Keyword.get(opts, :driver)),
         :ok <- validate_status(Keyword.get(opts, :status, :idle)),
         :ok <- validate_list(queue, :queue),
         :ok <- validate_list(outputs, :outputs),
         {:ok, trajectory} <-
           normalize_trajectory(
             Keyword.get(opts, :trajectory),
             kind,
             recipe,
             metadata
           ),
         :ok <- validate_map(measurements, :measurements),
         :ok <- validate_map(metadata, :metadata),
         {:ok, trace_sinks} <- Sink.normalize_input(Keyword.get(opts, :trace_sinks, [])),
         :ok <- validate_id(id) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         recipe: recipe,
         driver: Keyword.get(opts, :driver),
         snapshot: Keyword.get(opts, :snapshot),
         status: Keyword.get(opts, :status, :idle),
         queue: queue,
         outputs: outputs,
         trajectory: trajectory,
         measurements: measurements,
         metadata: metadata,
         trace_sinks: trace_sinks
       }}
    end
  end

  @spec new!(:turn_processor | :integrated, module(), keyword()) :: t()
  def new!(kind, recipe, opts \\ []) do
    case new(kind, recipe, opts) do
      {:ok, session} -> session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = session) do
    new(session.kind, session.recipe,
      id: session.id,
      driver: session.driver,
      snapshot: session.snapshot,
      status: session.status,
      queue: session.queue,
      outputs: session.outputs,
      trajectory: session.trajectory,
      measurements: session.measurements,
      metadata: session.metadata,
      trace_sinks: session.trace_sinks
    )
  end

  @spec enqueue(t(), term()) :: t()
  def enqueue(%__MODULE__{} = session, value) do
    %__MODULE__{
      session
      | queue: session.queue ++ [value],
        status: next_queue_status(session.status)
    }
  end

  @spec dequeue(t()) :: {:ok, {term(), t()}} | :empty
  def dequeue(%__MODULE__{queue: [value | rest]} = session) do
    {:ok, {value, %__MODULE__{session | queue: rest, status: next_dequeue_status(rest)}}}
  end

  def dequeue(%__MODULE__{}), do: :empty

  @spec with_snapshot(t(), term()) :: t()
  def with_snapshot(%__MODULE__{} = session, snapshot),
    do: %__MODULE__{session | snapshot: snapshot}

  @spec with_status(t(), atom()) :: t()
  def with_status(%__MODULE__{} = session, status) when status in @valid_statuses do
    %__MODULE__{session | status: status}
  end

  @spec append_output(t(), term()) :: t()
  def append_output(%__MODULE__{} = session, output) do
    %__MODULE__{session | outputs: session.outputs ++ [output]}
  end

  @spec with_trajectory(t(), Trajectory.t()) :: t()
  def with_trajectory(%__MODULE__{} = session, %Trajectory{} = trajectory) do
    %__MODULE__{session | trajectory: trajectory}
  end

  @spec with_measurements(t(), map()) :: t()
  def with_measurements(%__MODULE__{} = session, measurements) when is_map(measurements) do
    %__MODULE__{session | measurements: measurements}
  end

  @spec with_trace_sinks(t(), [Sink.normalized_sink()]) :: t()
  def with_trace_sinks(%__MODULE__{} = session, trace_sinks) when is_list(trace_sinks) do
    %__MODULE__{session | trace_sinks: trace_sinks}
  end

  defp normalize_trajectory(nil, kind, recipe, metadata) do
    Trajectory.new(
      recipe: recipe,
      session_kind: kind,
      metadata: metadata
    )
  end

  defp normalize_trajectory(%Trajectory{} = trajectory, _kind, _recipe, _metadata) do
    Trajectory.validate(trajectory)
  end

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid harness session kind",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_recipe(recipe) when is_atom(recipe), do: :ok

  defp validate_recipe(recipe) do
    {:error,
     Error.validation("harness session recipe must be a module",
       source: __MODULE__,
       details: %{recipe: recipe}
     )}
  end

  defp validate_driver(driver) when is_atom(driver), do: :ok

  defp validate_driver(driver) do
    {:error,
     Error.validation("harness session driver must be a module",
       source: __MODULE__,
       details: %{driver: driver}
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid harness session status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("harness session #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("harness session #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_id(value) when is_binary(value) and value != "", do: :ok

  defp validate_id(value) do
    {:error,
     Error.validation("harness session id must be a non-empty string",
       source: __MODULE__,
       details: %{id: value}
     )}
  end

  defp next_queue_status(:error), do: :error
  defp next_queue_status(:waiting), do: :waiting
  defp next_queue_status(:review), do: :review
  defp next_queue_status(:completed), do: :queued
  defp next_queue_status(_status), do: :queued

  defp next_dequeue_status([]), do: :idle
  defp next_dequeue_status(_rest), do: :queued

  defp default_id(kind), do: "session:#{kind}:#{System.unique_integer([:positive])}"
end
