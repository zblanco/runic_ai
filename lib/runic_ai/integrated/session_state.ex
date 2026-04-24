defmodule RunicAI.Integrated.SessionState do
  @moduledoc """
  Workflow-owned live state for one integrated agent lane.
  """

  alias RunicAI.Agent.State, as: AgentState
  alias RunicAI.Error
  alias RunicAI.Integrated.AgentRef
  alias RunicAI.Integrated.PendingWork
  alias RunicAI.Integrated.Signal

  @valid_statuses [:idle, :queued, :running, :waiting, :review, :completed, :halted]

  @default_control %{
    attempts: 0,
    retries: 0,
    model_calls: 0,
    tool_calls: 0,
    token_usage: %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0
    },
    last_budget_snapshot: nil
  }

  @enforce_keys [:agent, :agent_state, :status, :inbox, :control, :metadata]
  defstruct [:agent, :agent_state, :status, :inbox, :pending_work, :control, :metadata]

  @type status :: :idle | :queued | :running | :waiting | :review | :completed | :halted

  @type t :: %__MODULE__{
          agent: AgentRef.t(),
          agent_state: AgentState.t(),
          status: status(),
          inbox: [Signal.t()],
          pending_work: PendingWork.t() | nil,
          control: map(),
          metadata: map()
        }

  @spec new(AgentRef.t() | String.t() | atom(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(agent, opts \\ []) when is_list(opts) do
    status = Keyword.get(opts, :status, :idle)
    control = Map.merge(@default_control, Keyword.get(opts, :control, %{}))
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_agent} <- normalize_agent(agent, opts),
         {:ok, agent_state} <- normalize_agent_state(Keyword.get(opts, :agent_state)),
         :ok <- validate_status(status),
         {:ok, inbox} <- normalize_inbox(Keyword.get(opts, :inbox, [])),
         {:ok, pending_work} <- normalize_pending_work(Keyword.get(opts, :pending_work)),
         :ok <- validate_control(control),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         agent: normalized_agent,
         agent_state: sync_agent_pending_action(agent_state, pending_work),
         status: status,
         inbox: inbox,
         pending_work: pending_work,
         control: control,
         metadata: metadata
       }
       |> reconcile_queue()}
    end
  end

  @spec new!(AgentRef.t() | String.t() | atom(), keyword()) :: t()
  def new!(agent, opts \\ []) do
    case new(agent, opts) do
      {:ok, session_state} -> session_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = session_state) do
    new(session_state.agent,
      agent_state: session_state.agent_state,
      status: session_state.status,
      inbox: session_state.inbox,
      pending_work: session_state.pending_work,
      control: session_state.control,
      metadata: session_state.metadata
    )
  end

  @spec with_status(t(), status()) :: {:ok, t()} | {:error, Error.t()}
  def with_status(%__MODULE__{} = session_state, status) do
    with :ok <- validate_status(status) do
      {:ok, reconcile_queue(%__MODULE__{session_state | status: status})}
    end
  end

  @spec with_status!(t(), status()) :: t()
  def with_status!(%__MODULE__{} = session_state, status) do
    case with_status(session_state, status) do
      {:ok, updated_session} -> updated_session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec with_agent_state(t(), AgentState.t()) :: {:ok, t()} | {:error, Error.t()}
  def with_agent_state(%__MODULE__{} = session_state, %AgentState{} = agent_state) do
    with {:ok, normalized_agent_state} <- AgentState.validate(agent_state) do
      {:ok,
       %__MODULE__{
         session_state
         | agent_state:
             sync_agent_pending_action(normalized_agent_state, session_state.pending_work)
       }}
    end
  end

  @spec with_agent_state!(t(), AgentState.t()) :: t()
  def with_agent_state!(%__MODULE__{} = session_state, %AgentState{} = agent_state) do
    case with_agent_state(session_state, agent_state) do
      {:ok, updated_session} -> updated_session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec with_pending_work(t(), PendingWork.t() | nil, keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def with_pending_work(%__MODULE__{} = session_state, pending_work, opts \\ []) do
    status = Keyword.get(opts, :status, session_state.status)

    with {:ok, pending_work} <- normalize_pending_work(pending_work),
         :ok <- validate_status(status) do
      {:ok,
       %__MODULE__{
         session_state
         | pending_work: pending_work,
           status: status,
           agent_state: sync_agent_pending_action(session_state.agent_state, pending_work)
       }
       |> reconcile_queue()}
    end
  end

  @spec with_pending_work!(t(), PendingWork.t() | nil, keyword()) :: t()
  def with_pending_work!(%__MODULE__{} = session_state, pending_work, opts \\ []) do
    case with_pending_work(session_state, pending_work, opts) do
      {:ok, updated_session} -> updated_session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec clear_pending_work(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def clear_pending_work(%__MODULE__{} = session_state, opts \\ []) do
    with_pending_work(session_state, nil, opts)
  end

  @spec clear_pending_work!(t(), keyword()) :: t()
  def clear_pending_work!(%__MODULE__{} = session_state, opts \\ []) do
    with_pending_work!(session_state, nil, opts)
  end

  @spec append_signal(t(), Signal.t()) :: {:ok, t()} | {:error, Error.t()}
  def append_signal(%__MODULE__{} = session_state, %Signal{} = signal) do
    with {:ok, signal} <- Signal.validate(signal) do
      {:ok,
       %__MODULE__{
         session_state
         | inbox: session_state.inbox ++ [signal],
           status: next_enqueued_status(session_state.status, signal)
       }
       |> reconcile_queue()}
    end
  end

  @spec append_signal!(t(), Signal.t()) :: t()
  def append_signal!(%__MODULE__{} = session_state, %Signal{} = signal) do
    case append_signal(session_state, signal) do
      {:ok, updated_session} -> updated_session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec prepend_signal(t(), Signal.t()) :: {:ok, t()} | {:error, Error.t()}
  def prepend_signal(%__MODULE__{} = session_state, %Signal{} = signal) do
    with {:ok, signal} <- Signal.validate(signal) do
      {:ok,
       %__MODULE__{
         session_state
         | inbox: [signal | session_state.inbox],
           status: next_enqueued_status(session_state.status, signal)
       }
       |> reconcile_queue()}
    end
  end

  @spec prepend_signal!(t(), Signal.t()) :: t()
  def prepend_signal!(%__MODULE__{} = session_state, %Signal{} = signal) do
    case prepend_signal(session_state, signal) do
      {:ok, updated_session} -> updated_session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec dequeue_signal(t()) :: {:ok, {Signal.t(), t()}} | {:error, Error.t()}
  def dequeue_signal(%__MODULE__{inbox: [%Signal{} = signal | rest]} = session_state) do
    {:ok, {signal, reconcile_queue(%__MODULE__{session_state | inbox: rest})}}
  end

  def dequeue_signal(%__MODULE__{} = session_state) do
    {:error,
     Error.validation("integrated session inbox is empty",
       source: __MODULE__,
       details: %{agent_id: session_state.agent.id}
     )}
  end

  @spec dequeue_signal!(t()) :: {Signal.t(), t()}
  def dequeue_signal!(%__MODULE__{} = session_state) do
    case dequeue_signal(session_state) do
      {:ok, dequeued} -> dequeued
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec next_signal(t()) :: Signal.t() | nil
  def next_signal(%__MODULE__{inbox: [%Signal{} = signal | _rest]}), do: signal
  def next_signal(%__MODULE__{}), do: nil

  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{status: :queued, inbox: [_ | _]}), do: true
  def ready?(%__MODULE__{}), do: false

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :halted]

  @spec reconcile_queue(t()) :: t()
  def reconcile_queue(%__MODULE__{status: status, inbox: inbox} = session_state)
      when status in [:idle, :queued] do
    normalized_status = if inbox == [], do: :idle, else: :queued
    %__MODULE__{session_state | status: normalized_status}
  end

  def reconcile_queue(%__MODULE__{} = session_state), do: session_state

  defp normalize_agent(%AgentRef{} = agent_ref, _opts), do: AgentRef.validate(agent_ref)
  defp normalize_agent(agent_id, opts), do: AgentRef.new(agent_id, opts)

  defp normalize_agent_state(nil), do: AgentState.new()
  defp normalize_agent_state(%AgentState{} = agent_state), do: AgentState.validate(agent_state)

  defp normalize_agent_state(agent_state) do
    {:error,
     Error.validation("integrated session agent_state must be an Agent.State",
       source: __MODULE__,
       details: %{agent_state: agent_state}
     )}
  end

  defp normalize_inbox(inbox) when is_list(inbox) do
    inbox
    |> Enum.reduce_while({:ok, []}, fn signal, {:ok, acc} ->
      case Signal.from_input(signal, []) do
        {:ok, normalized_signal} -> {:cont, {:ok, [normalized_signal | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_signals} -> {:ok, Enum.reverse(normalized_signals)}
      error -> error
    end
  end

  defp normalize_inbox(inbox) do
    {:error,
     Error.validation("integrated session inbox must be a list, got: #{inspect(inbox)}",
       source: __MODULE__
     )}
  end

  defp normalize_pending_work(nil), do: {:ok, nil}

  defp normalize_pending_work(%PendingWork{} = pending_work),
    do: PendingWork.validate(pending_work)

  defp normalize_pending_work(other) do
    {:error,
     Error.validation("integrated session pending_work must be a PendingWork or nil",
       source: __MODULE__,
       details: %{pending_work: other}
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid integrated session status: #{inspect(status)}",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_control(control) when is_map(control), do: :ok

  defp validate_control(control) do
    {:error,
     Error.validation("integrated session control must be a map, got: #{inspect(control)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("integrated session metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp sync_agent_pending_action(%AgentState{} = agent_state, %PendingWork{
         kind: kind,
         request: request
       })
       when kind in [:review, :wait] do
    AgentState.with_pending_action!(agent_state, request)
  end

  defp sync_agent_pending_action(%AgentState{} = agent_state, _pending_work) do
    AgentState.clear_pending_action!(agent_state)
  end

  defp next_enqueued_status(status, %Signal{} = signal) do
    cond do
      status in [:completed, :halted] ->
        status

      status in [:waiting] and signal.kind in [:resume, :wake] ->
        :queued

      status in [:review] and signal.kind == :review_decision ->
        :queued

      status in [:idle] and Signal.turn_signal?(signal) ->
        :queued

      status in [:idle] and signal.kind == :stop ->
        :halted

      true ->
        status
    end
  end
end
