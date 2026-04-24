defmodule RunicAI.Runtime.SessionServer do
  @moduledoc """
  Generic GenServer shell for long-lived RunicAI harness sessions.
  """

  use GenServer

  alias RunicAI.Error
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session
  alias RunicAI.ResumeSignal
  alias RunicAI.Runtime.Handle
  alias RunicAI.Runtime.Registry, as: RuntimeRegistry
  alias RunicAI.Runtime.SessionSpec
  alias RunicAI.Wait

  defstruct [
    :spec,
    :backend,
    :backend_state,
    :scheduler,
    :scheduler_state,
    :handle,
    subscribers: MapSet.new()
  ]

  @type t :: %__MODULE__{
          spec: SessionSpec.t(),
          backend: module(),
          backend_state: term(),
          scheduler: module(),
          scheduler_state: term(),
          handle: Handle.t(),
          subscribers: MapSet.t(pid())
        }

  @spec child_spec(SessionSpec.t() | keyword()) :: Supervisor.child_spec()
  def child_spec(spec_or_opts) do
    spec = SessionSpec.from_input!(spec_or_opts)

    %{
      id: {__MODULE__, spec.id},
      start: {__MODULE__, :start_link, [spec]},
      restart: :transient,
      type: :worker
    }
  end

  @spec start_link(SessionSpec.t() | keyword()) :: GenServer.on_start()
  def start_link(spec_or_opts) do
    spec = SessionSpec.from_input!(spec_or_opts)
    GenServer.start_link(__MODULE__, spec, name: RuntimeRegistry.via(spec.id))
  end

  @spec handle(GenServer.server()) :: Handle.t()
  def handle(server), do: GenServer.call(server, :handle, :infinity)

  @spec submit(GenServer.server(), term()) :: {:ok, Session.t()} | {:error, Error.t()}
  def submit(server, input), do: GenServer.call(server, {:submit, input}, :infinity)

  @spec advance(GenServer.server(), Policy.t() | keyword() | nil) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def advance(server, policy \\ nil), do: GenServer.call(server, {:advance, policy}, :infinity)

  @spec drain(GenServer.server(), Policy.t() | keyword() | nil) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def drain(server, policy \\ nil), do: GenServer.call(server, {:drain, policy}, :infinity)

  @spec snapshot(GenServer.server()) :: Session.t()
  def snapshot(server), do: GenServer.call(server, :snapshot, :infinity)

  @spec outputs(GenServer.server()) :: list()
  def outputs(server), do: GenServer.call(server, :outputs, :infinity)

  @spec trajectory(GenServer.server()) :: RunicAI.Trace.Trajectory.t()
  def trajectory(server), do: GenServer.call(server, :trajectory, :infinity)

  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server), do: GenServer.call(server, {:subscribe, self()}, :infinity)

  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server), do: GenServer.call(server, {:unsubscribe, self()}, :infinity)

  @impl true
  def init(%SessionSpec{} = spec) do
    with {:ok, backend_state} <- spec.backend.init(spec),
         {:ok, scheduler_state} <- spec.scheduler.init(spec.scheduler_opts) do
      handle =
        Handle.new!(spec, self(),
          runner_workflow_id: backend_runner_workflow_id(backend_state, spec),
          metadata: Map.merge(spec.metadata, backend_metadata(backend_state))
        )

      state = %__MODULE__{
        spec: spec,
        backend: spec.backend,
        backend_state: backend_state,
        scheduler: spec.scheduler,
        scheduler_state: scheduler_state,
        handle: handle
      }

      {:ok, state}
    else
      {:error, %Error{} = error} -> {:stop, error}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:handle, _from, %__MODULE__{} = state) do
    {:reply, state.handle, state}
  end

  def handle_call({:submit, input}, _from, %__MODULE__{} = state) do
    state
    |> transition(fn backend, backend_state -> backend.submit(backend_state, input) end)
    |> reply_transition()
  end

  def handle_call({:advance, policy_input}, _from, %__MODULE__{} = state) do
    with {:ok, policy} <- effective_policy(state, policy_input) do
      state
      |> transition(fn backend, backend_state -> backend.advance(backend_state, policy) end)
      |> reply_transition()
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:drain, policy_input}, _from, %__MODULE__{} = state) do
    with {:ok, policy} <- effective_policy(state, policy_input) do
      state
      |> transition(fn backend, backend_state -> backend.drain(backend_state, policy) end)
      |> reply_transition()
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:snapshot, _from, %__MODULE__{} = state) do
    {:reply, state.backend.session(state.backend_state), state}
  end

  def handle_call(:outputs, _from, %__MODULE__{} = state) do
    {:reply, state.backend.outputs(state.backend_state), state}
  end

  def handle_call(:trajectory, _from, %__MODULE__{} = state) do
    {:reply, state.backend.trajectory(state.backend_state), state}
  end

  def handle_call({:subscribe, pid}, _from, %__MODULE__{} = state) when is_pid(pid) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, %__MODULE__{} = state) when is_pid(pid) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info({:runic_ai_runtime_wake, %Wait{} = wait}, %__MODULE__{} = state) do
    wake_input = wake_input(wait, state.backend.session(state.backend_state))

    next_state =
      state
      |> transition(fn backend, backend_state -> backend.submit(backend_state, wake_input) end)
      |> case do
        {:ok, submitted_state, _previous_session} ->
          case effective_policy(submitted_state, nil) do
            {:ok, policy} ->
              transition(submitted_state, fn backend, backend_state ->
                backend.drain(backend_state, policy)
              end)

            {:error, error} ->
              {:error, submitted_state, error}
          end

        other ->
          other
      end
      |> case do
        {:ok, updated_state, _previous_session} -> updated_state
        {:error, current_state, _error} -> current_state
      end

    {:noreply, next_state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    _ = state.scheduler.shutdown(state.scheduler_state)
    _ = state.backend.shutdown(state.backend_state)
    :ok
  end

  defp transition(%__MODULE__{} = state, fun) when is_function(fun, 2) do
    previous_session = state.backend.session(state.backend_state)

    case fun.(state.backend, state.backend_state) do
      {:ok, backend_state} ->
        state = %{state | backend_state: backend_state}
        current_session = state.backend.session(state.backend_state)
        state = maybe_schedule_wait(state, previous_session, current_session)

        state = notify_subscribers(state, previous_session, current_session)

        {:ok, state, previous_session}

      {:error, %Error{} = error} ->
        {:error, state, error}

      {:error, reason} ->
        {:error, state, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp reply_transition({:ok, state, _previous_session}) do
    {:reply, {:ok, state.backend.session(state.backend_state)}, state}
  end

  defp reply_transition({:error, state, error}) do
    {:reply, {:error, error}, state}
  end

  defp effective_policy(%__MODULE__{spec: spec}, nil), do: {:ok, spec.policy}
  defp effective_policy(%__MODULE__{}, %Policy{} = policy), do: Policy.validate(policy)
  defp effective_policy(%__MODULE__{}, policy_input), do: Policy.from_input(policy_input)

  defp maybe_schedule_wait(%__MODULE__{} = state, %Session{} = previous, %Session{} = current) do
    case latest_wait(current) do
      %Wait{} = wait ->
        if new_wait?(wait, previous, current) do
          case state.scheduler.schedule(wait, self(), state.scheduler_state) do
            {:ok, scheduler_state} -> %{state | scheduler_state: scheduler_state}
            {:error, _reason} -> state
          end
        else
          state
        end

      nil ->
        state
    end
  end

  defp new_wait?(%Wait{} = wait, %Session{} = previous, %Session{} = current) do
    previous_wait = latest_wait(previous)

    is_nil(previous_wait) or previous_wait.resume_key != wait.resume_key or
      length(current.outputs) > length(previous.outputs)
  end

  defp latest_wait(%Session{outputs: outputs}) do
    outputs
    |> List.last()
    |> case do
      %{wait: %Wait{} = wait} -> wait
      %{latest_wait: %Wait{} = wait} -> wait
      _other -> nil
    end
  end

  defp wake_input(%Wait{} = wait, %Session{kind: :integrated}) do
    %{
      wake: %{
        resume_key: wait.resume_key,
        payload: wait.payload,
        scheduled_for:
          wait.until || Map.get(wait.metadata, :until) || Map.get(wait.metadata, "until")
      }
    }
  end

  defp wake_input(%Wait{} = wait, %Session{kind: :turn_processor}) do
    ResumeSignal.new!(:wake, wait.resume_key,
      payload: wait.payload,
      metadata: %{
        scheduled_for:
          wait.until || Map.get(wait.metadata, :until) || Map.get(wait.metadata, "until")
      }
    )
  end

  defp notify_subscribers(%__MODULE__{} = state, %Session{} = previous, %Session{} = current) do
    new_events = Enum.drop(current.trajectory.events, length(previous.trajectory.events))
    new_outputs = Enum.drop(current.outputs, length(previous.outputs))

    Enum.each(state.subscribers, fn subscriber ->
      Enum.each(new_events, fn event ->
        send(subscriber, {:runic_ai_runtime, current.id, :trace_event, event})
      end)

      Enum.each(new_outputs, fn output ->
        send(subscriber, {:runic_ai_runtime, current.id, :output, output})
      end)

      if previous.snapshot != current.snapshot or previous.status != current.status do
        send(subscriber, {:runic_ai_runtime, current.id, :snapshot, current})
      end
    end)

    state
  end

  defp backend_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp backend_metadata(_backend_state), do: %{}

  defp backend_runner_workflow_id(%{workflow_id: workflow_id}, _spec), do: workflow_id
  defp backend_runner_workflow_id(_backend_state, spec), do: spec.runner_workflow_id
end
