defmodule RunicAI.Integrated.RuntimeState do
  @moduledoc """
  Authoritative workflow-owned state for the whole integrated runtime.
  """

  alias RunicAI.Error
  alias RunicAI.Integrated.PendingWork
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Integrated.Signal
  alias RunicAI.Wait

  @enforce_keys [:agents, :ready_queue, :resume_index, :scheduled, :metadata]
  defstruct agents: %{}, ready_queue: [], resume_index: %{}, scheduled: %{}, metadata: %{}

  @type session_update :: %{
          required(:session) => SessionState.t(),
          optional(:prepend_signals) => [Signal.t()],
          optional(:emissions) => list()
        }

  @type t :: %__MODULE__{
          agents: %{optional(String.t()) => SessionState.t()},
          ready_queue: [String.t()],
          resume_index: %{optional(String.t()) => String.t()},
          scheduled: %{optional(String.t()) => map()},
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, agents} <- normalize_agents(Keyword.get(opts, :agents, [])),
         {:ok, ready_queue} <- normalize_ready_queue(Keyword.get(opts, :ready_queue, []), agents),
         {:ok, resume_index} <- normalize_resume_index(Keyword.get(opts, :resume_index, %{})),
         {:ok, scheduled} <- normalize_scheduled(Keyword.get(opts, :scheduled, %{})),
         :ok <- validate_metadata(metadata) do
      runtime =
        %__MODULE__{
          agents: agents,
          ready_queue: ready_queue,
          resume_index: resume_index,
          scheduled: scheduled,
          metadata: metadata
        }
        |> rebuild_indexes()

      {:ok, runtime}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, runtime_state} -> runtime_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = runtime_state) do
    new(
      agents: runtime_state.agents,
      ready_queue: runtime_state.ready_queue,
      resume_index: runtime_state.resume_index,
      scheduled: runtime_state.scheduled,
      metadata: runtime_state.metadata
    )
  end

  @spec reduce(t(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def reduce(runtime_state, input, opts \\ [])

  def reduce(%__MODULE__{} = runtime_state, %Signal{} = signal, opts) do
    with {:ok, signal} <- Signal.validate(signal) do
      apply_signal(runtime_state, signal, opts)
    end
  end

  def reduce(%__MODULE__{} = runtime_state, %{session: %SessionState{} = session} = update, _opts) do
    apply_session_update(runtime_state, session, update)
  end

  def reduce(%__MODULE__{} = runtime_state, %SessionState{} = session, _opts) do
    apply_session_update(runtime_state, session, %{})
  end

  def reduce(%__MODULE__{} = runtime_state, other, opts) do
    with {:ok, signal} <- Signal.from_input(other, Keyword.take(opts, [:default_agent_id])) do
      apply_signal(runtime_state, signal, opts)
    end
  end

  @spec reduce!(t(), term(), keyword()) :: t()
  def reduce!(%__MODULE__{} = runtime_state, input, opts \\ []) do
    case reduce(runtime_state, input, opts) do
      {:ok, updated_runtime} -> updated_runtime
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec fetch_agent(t(), String.t() | atom()) :: {:ok, SessionState.t()} | :error
  def fetch_agent(%__MODULE__{} = runtime_state, agent_id) when is_atom(agent_id),
    do: fetch_agent(runtime_state, Atom.to_string(agent_id))

  def fetch_agent(%__MODULE__{agents: agents}, agent_id) when is_binary(agent_id),
    do: Map.fetch(agents, agent_id)

  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{} = runtime_state) do
    match?({:ok, _bundle}, next_ready(runtime_state))
  end

  @spec next_ready(t()) ::
          {:ok,
           %{runtime: t(), agent_id: String.t(), session: SessionState.t(), signal: Signal.t()}}
          | :empty
  def next_ready(%__MODULE__{} = runtime_state) do
    runtime_state.ready_queue
    |> Enum.find_value(fn agent_id ->
      case Map.get(runtime_state.agents, agent_id) do
        %SessionState{} = session ->
          if SessionState.ready?(session) do
            case SessionState.next_signal(session) do
              %Signal{} = signal ->
                {:ok,
                 %{
                   runtime: runtime_state,
                   agent_id: agent_id,
                   session: session,
                   signal: signal
                 }}

              _ ->
                nil
            end
          else
            nil
          end

        _ ->
          nil
      end
    end) || :empty
  end

  @spec agent_for_resume_key(t(), String.t()) :: {:ok, String.t()} | :error
  def agent_for_resume_key(%__MODULE__{resume_index: resume_index}, resume_key)
      when is_binary(resume_key) do
    Map.fetch(resume_index, resume_key)
  end

  defp apply_signal(%__MODULE__{} = runtime_state, %Signal{kind: :stop} = signal, opts) do
    with {:ok, agent_id} <- resolve_agent_id(runtime_state, signal, opts) do
      case Map.fetch(runtime_state.agents, agent_id) do
        {:ok, %SessionState{} = session} ->
          halted_agent_state = RunicAI.Agent.State.with_status!(session.agent_state, :halted)

          halted_session =
            session
            |> SessionState.clear_pending_work!(status: :halted)
            |> SessionState.with_agent_state!(halted_agent_state)
            |> Map.put(:inbox, [])

          {:ok, replace_session(runtime_state, halted_session)}

        :error ->
          {:ok, runtime_state}
      end
    end
  end

  defp apply_signal(%__MODULE__{} = runtime_state, %Signal{} = signal, opts) do
    with {:ok, agent_id} <- resolve_or_create_agent_id(runtime_state, signal, opts),
         {:ok, session} <- fetch_or_build_session(runtime_state, agent_id, signal, opts) do
      updated_session = SessionState.append_signal!(session, %Signal{signal | agent_id: agent_id})
      {:ok, replace_session(runtime_state, updated_session)}
    end
  end

  defp apply_session_update(%__MODULE__{} = runtime_state, %SessionState{} = session, update) do
    with {:ok, session} <- SessionState.validate(session),
         {:ok, prepend_signals} <-
           normalize_prepend_signals(Map.get(update, :prepend_signals, [])) do
      updated_session =
        Enum.reduce(Enum.reverse(prepend_signals), session, fn signal, acc ->
          SessionState.prepend_signal!(acc, signal)
        end)

      {:ok, replace_session(runtime_state, updated_session)}
    end
  end

  defp replace_session(%__MODULE__{} = runtime_state, %SessionState{} = session_state) do
    runtime_state
    |> drop_indexes(session_state.agent.id)
    |> then(fn runtime ->
      %__MODULE__{
        runtime
        | agents: Map.put(runtime.agents, session_state.agent.id, session_state)
      }
    end)
    |> rebuild_indexes()
  end

  defp drop_indexes(%__MODULE__{} = runtime_state, agent_id) do
    %__MODULE__{
      runtime_state
      | ready_queue: Enum.reject(runtime_state.ready_queue, &(&1 == agent_id)),
        resume_index:
          runtime_state.resume_index
          |> Enum.reject(fn {_resume_key, indexed_agent_id} -> indexed_agent_id == agent_id end)
          |> Map.new(),
        scheduled:
          runtime_state.scheduled
          |> Enum.reject(fn {_resume_key, entry} -> Map.get(entry, :agent_id) == agent_id end)
          |> Map.new()
    }
  end

  defp rebuild_indexes(%__MODULE__{} = runtime_state) do
    Enum.reduce(
      runtime_state.agents,
      %__MODULE__{runtime_state | ready_queue: [], resume_index: %{}, scheduled: %{}},
      fn {agent_id, session}, runtime ->
        runtime
        |> maybe_register_ready(agent_id, session)
        |> maybe_register_resume(agent_id, session.pending_work)
        |> maybe_register_schedule(agent_id, session.pending_work)
      end
    )
  end

  defp maybe_register_ready(%__MODULE__{} = runtime_state, agent_id, %SessionState{} = session) do
    if SessionState.ready?(session) do
      %__MODULE__{runtime_state | ready_queue: runtime_state.ready_queue ++ [agent_id]}
    else
      runtime_state
    end
  end

  defp maybe_register_resume(%__MODULE__{} = runtime_state, agent_id, %PendingWork{
         resume_key: resume_key
       })
       when is_binary(resume_key) do
    %__MODULE__{
      runtime_state
      | resume_index: Map.put(runtime_state.resume_index, resume_key, agent_id)
    }
  end

  defp maybe_register_resume(%__MODULE__{} = runtime_state, _agent_id, _pending_work),
    do: runtime_state

  defp maybe_register_schedule(
         %__MODULE__{} = runtime_state,
         agent_id,
         %PendingWork{request: %Wait{resume_key: resume_key, until: %DateTime{} = wait_until}}
       ) do
    %__MODULE__{
      runtime_state
      | scheduled:
          Map.put(runtime_state.scheduled, resume_key, %{
            agent_id: agent_id,
            resume_key: resume_key,
            until: wait_until
          })
    }
  end

  defp maybe_register_schedule(%__MODULE__{} = runtime_state, _agent_id, _pending_work),
    do: runtime_state

  defp resolve_or_create_agent_id(%__MODULE__{} = runtime_state, %Signal{} = signal, opts) do
    case resolve_agent_id(runtime_state, signal, opts) do
      {:ok, agent_id} ->
        {:ok, agent_id}

      :error ->
        if signal.kind in [:start, :receive_turn, :spawn] do
          case Keyword.get(opts, :default_agent_id) ||
                 Map.get(runtime_state.metadata, :default_agent_id) do
            nil -> {:error, missing_agent_error(signal)}
            agent_id when is_binary(agent_id) -> {:ok, agent_id}
            agent_id when is_atom(agent_id) -> {:ok, Atom.to_string(agent_id)}
          end
        else
          {:error, missing_agent_error(signal)}
        end
    end
  end

  defp resolve_agent_id(%__MODULE__{} = _runtime_state, %Signal{agent_id: agent_id}, _opts)
       when is_binary(agent_id),
       do: {:ok, agent_id}

  defp resolve_agent_id(%__MODULE__{} = runtime_state, %Signal{} = signal, opts) do
    case Signal.resume_key(signal) do
      resume_key when is_binary(resume_key) ->
        case agent_for_resume_key(runtime_state, resume_key) do
          {:ok, agent_id} -> {:ok, agent_id}
          :error -> :error
        end

      nil ->
        case Keyword.get(opts, :default_agent_id) ||
               Map.get(runtime_state.metadata, :default_agent_id) do
          agent_id when is_binary(agent_id) -> {:ok, agent_id}
          agent_id when is_atom(agent_id) -> {:ok, Atom.to_string(agent_id)}
          _ -> :error
        end
    end
  end

  defp fetch_or_build_session(%__MODULE__{} = runtime_state, agent_id, %Signal{} = signal, opts) do
    case Map.fetch(runtime_state.agents, agent_id) do
      {:ok, %SessionState{} = session} ->
        {:ok, session}

      :error ->
        build_session(agent_id, signal, opts)
    end
  end

  defp build_session(agent_id, signal, opts) do
    case Keyword.get(opts, :session_builder) do
      builder when is_function(builder, 2) ->
        case builder.(agent_id, signal) do
          %SessionState{} = session -> SessionState.validate(session)
          {:ok, %SessionState{} = session} -> SessionState.validate(session)
          {:error, error} -> {:error, error}
          other -> invalid_session_builder_error(other)
        end

      builder when is_function(builder, 1) ->
        case builder.(agent_id) do
          %SessionState{} = session -> SessionState.validate(session)
          {:ok, %SessionState{} = session} -> SessionState.validate(session)
          {:error, error} -> {:error, error}
          other -> invalid_session_builder_error(other)
        end

      nil ->
        {:error, missing_agent_error(signal)}
    end
  end

  defp invalid_session_builder_error(other) do
    {:error,
     Error.validation("integrated session_builder must return a SessionState",
       source: __MODULE__,
       details: %{result: other}
     )}
  end

  defp missing_agent_error(%Signal{} = signal) do
    Error.validation("integrated runtime could not resolve an agent_id for the signal",
      source: __MODULE__,
      details: %{signal: signal}
    )
  end

  defp normalize_agents(agents) when is_map(agents) do
    agents
    |> Enum.reduce_while({:ok, %{}}, fn {agent_id, session}, {:ok, acc} ->
      case normalize_session_entry(agent_id, session) do
        {:ok, {normalized_agent_id, normalized_session}} ->
          {:cont, {:ok, Map.put(acc, normalized_agent_id, normalized_session)}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_agents(agents) when is_list(agents) do
    agents
    |> Enum.reduce_while({:ok, %{}}, fn session, {:ok, acc} ->
      case normalize_session_entry(nil, session) do
        {:ok, {normalized_agent_id, normalized_session}} ->
          {:cont, {:ok, Map.put(acc, normalized_agent_id, normalized_session)}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_agents(agents) do
    {:error,
     Error.validation("integrated runtime agents must be a map or list",
       source: __MODULE__,
       details: %{agents: agents}
     )}
  end

  defp normalize_session_entry(nil, %SessionState{} = session) do
    with {:ok, session} <- SessionState.validate(session) do
      {:ok, {session.agent.id, session}}
    end
  end

  defp normalize_session_entry(agent_id, %SessionState{} = session) do
    with {:ok, session} <- SessionState.validate(session),
         true <- session.agent.id == to_string(agent_id) or is_nil(agent_id) do
      {:ok, {session.agent.id, session}}
    else
      false ->
        {:error,
         Error.validation("integrated runtime agent map key must match the session agent id",
           source: __MODULE__,
           details: %{agent_id: agent_id, session_agent_id: session.agent.id}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_session_entry(_agent_id, session) do
    {:error,
     Error.validation("integrated runtime agents must contain SessionState values",
       source: __MODULE__,
       details: %{session: session}
     )}
  end

  defp normalize_ready_queue(ready_queue, _agents) when is_list(ready_queue) do
    {:ok,
     ready_queue
     |> Enum.map(fn
       agent_id when is_atom(agent_id) -> Atom.to_string(agent_id)
       agent_id -> agent_id
     end)
     |> Enum.filter(&is_binary/1)
     |> Enum.uniq()}
  end

  defp normalize_ready_queue(ready_queue, _agents) do
    {:error,
     Error.validation("integrated runtime ready_queue must be a list",
       source: __MODULE__,
       details: %{ready_queue: ready_queue}
     )}
  end

  defp normalize_resume_index(resume_index) when is_map(resume_index), do: {:ok, resume_index}

  defp normalize_resume_index(resume_index) do
    {:error,
     Error.validation("integrated runtime resume_index must be a map",
       source: __MODULE__,
       details: %{resume_index: resume_index}
     )}
  end

  defp normalize_scheduled(scheduled) when is_map(scheduled), do: {:ok, scheduled}

  defp normalize_scheduled(scheduled) do
    {:error,
     Error.validation("integrated runtime scheduled must be a map",
       source: __MODULE__,
       details: %{scheduled: scheduled}
     )}
  end

  defp normalize_prepend_signals(signals) when is_list(signals) do
    signals
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

  defp normalize_prepend_signals(signals) do
    {:error,
     Error.validation("integrated runtime prepend_signals must be a list",
       source: __MODULE__,
       details: %{prepend_signals: signals}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("integrated runtime metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
