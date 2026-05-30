defmodule RunicSandbox.Manager do
  @moduledoc false

  use GenServer

  alias RunicSandbox.AttachHandle
  alias RunicSandbox.Error
  alias RunicSandbox.ExecutionRequest
  alias RunicSandbox.Lease
  alias RunicSandbox.Profile
  alias RunicSandbox.Session

  defstruct profiles: %{}, instances: %{}, sessions: %{}, leases: %{}, reaper_ref: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, RunicSandbox))
  end

  @spec exec(GenServer.server(), ExecutionRequest.t() | keyword() | map()) ::
          {:ok, RunicSandbox.ExecutionResult.t()} | {:error, Error.t()}
  def exec(server, request), do: GenServer.call(server, {:exec, request}, :infinity)

  @spec open_session(GenServer.server(), atom(), keyword() | map()) ::
          {:ok, RunicSandbox.Session.t()} | {:error, Error.t()}
  def open_session(server, sandbox, spec),
    do: GenServer.call(server, {:open_session, sandbox, spec}, :infinity)

  @spec acquire_session(GenServer.server(), atom(), keyword() | map()) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def acquire_session(server, sandbox, spec),
    do: GenServer.call(server, {:acquire_session, sandbox, spec}, :infinity)

  @spec release_session(GenServer.server(), Session.t(), keyword()) :: :ok | {:error, Error.t()}
  def release_session(server, %Session{} = session, opts),
    do: GenServer.call(server, {:release_session, session, opts}, :infinity)

  @spec attach(
          GenServer.server(),
          Session.t(),
          ExecutionRequest.t() | keyword() | map(),
          keyword()
        ) ::
          {:ok, AttachHandle.t()} | {:error, Error.t()}
  def attach(server, %Session{} = session, request, opts) do
    with {:ok, managed_session} <- prepare_attach(server, session),
         {:ok, handle} <-
           RunicSandbox.attach(managed_session, request, Keyword.delete(opts, :server)) do
      register_attach(server, managed_session, handle)
    end
  end

  @spec prepare_attach(GenServer.server(), Session.t()) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def prepare_attach(server, %Session{} = session),
    do: GenServer.call(server, {:prepare_attach, session}, :infinity)

  @spec register_attach(GenServer.server(), Session.t(), AttachHandle.t()) ::
          {:ok, AttachHandle.t()} | {:error, Error.t()}
  def register_attach(server, %Session{} = session, %AttachHandle{} = handle),
    do: GenServer.call(server, {:register_attach, session, handle}, :infinity)

  @spec close_attach(GenServer.server(), AttachHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_attach(server, %AttachHandle{} = handle, opts),
    do: GenServer.call(server, {:close_attach, handle, opts}, :infinity)

  @spec close_session(GenServer.server(), Session.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_session(server, %Session{} = session, opts),
    do: GenServer.call(server, {:close_session, session, opts}, :infinity)

  @spec reset_session(GenServer.server(), Session.t(), keyword()) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def reset_session(server, %Session{} = session, opts),
    do: GenServer.call(server, {:reset_session, session, opts}, :infinity)

  @spec acquire_lease(GenServer.server(), Session.t(), String.t(), keyword()) ::
          {:ok, Lease.t()} | {:error, Error.t()}
  def acquire_lease(server, %Session{} = session, resource, opts),
    do: GenServer.call(server, {:acquire_lease, session, resource, opts}, :infinity)

  @spec release_lease(GenServer.server(), Lease.t(), keyword()) :: :ok | {:error, Error.t()}
  def release_lease(server, %Lease{} = lease, opts),
    do: GenServer.call(server, {:release_lease, lease, opts}, :infinity)

  @spec status(GenServer.server(), atom() | nil) :: {:ok, map()} | {:error, Error.t()}
  def status(server, sandbox \\ nil), do: GenServer.call(server, {:status, sandbox})

  @impl true
  def init(opts) do
    with {:ok, profiles} <- profiles(Keyword.get(opts, :sandboxes, [])),
         {:ok, state} <- warm_state(%__MODULE__{profiles: profiles}) do
      {:ok, schedule_reaper(state)}
    else
      {:error, error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:exec, request_input}, _from, state) do
    with {:ok, request} <- ExecutionRequest.new(request_input),
         {:ok, profile} <- fetch_profile(state, request.sandbox),
         :ok <- RunicSandbox.authorize_request(profile, request),
         {:ok, session, state} <- checkout_session(state, profile, []) do
      result = RunicSandbox.exec(session, request)
      reply_after_checkin(result, checkin_session(state, session, profile, []), state)
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:open_session, sandbox, spec}, {caller_pid, _tag}, state) do
    with {:ok, profile} <- fetch_profile(state, sandbox),
         {:ok, session, state} <- checkout_session(state, profile, spec, caller_pid) do
      {:reply, {:ok, session}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:acquire_session, sandbox, spec}, {caller_pid, _tag}, state) do
    with {:ok, profile} <- fetch_profile(state, sandbox),
         {:ok, session, state} <- checkout_session(state, profile, spec, caller_pid) do
      {:reply, {:ok, session}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:release_session, session, opts}, _from, state) do
    with {:ok, profile} <- fetch_profile(state, session.sandbox),
         checkin_result <- checkin_session(state, session, profile, opts) do
      reply_after_checkin(:ok, checkin_result, state)
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:prepare_attach, session}, _from, state) do
    with {:ok, _id, entry} <- fetch_entry(state, session),
         :ok <- validate_entry_handle(entry, session) do
      {:reply, {:ok, entry.session}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:register_attach, session, handle}, _from, state) do
    with {:ok, id, entry} <- fetch_entry(state, session),
         :ok <- validate_entry_handle(entry, session),
         :ok <- validate_attach_handle(entry, handle) do
      managed_handle = managed_attach_handle(handle, self())
      state = put_active_attach(state, id, entry, managed_handle)
      {:reply, {:ok, managed_handle}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:close_attach, handle, opts}, _from, state) do
    case fetch_active_attach(state, handle) do
      {:ok, id, entry} ->
        result = RunicSandbox.close_attach(handle, Keyword.delete(opts, :server))
        state = delete_active_attach(state, id, entry, handle)
        {:reply, result, state}

      :not_found ->
        {:reply, RunicSandbox.close_attach(handle, Keyword.delete(opts, :server)), state}
    end
  end

  def handle_call({:close_session, session, opts}, _from, state) do
    with {:ok, id, entry} <- fetch_entry(state, session),
         :ok <- validate_entry_handle(entry, session),
         :ok <- validate_no_active_leases(state, session),
         {close_results, state} <- close_entry_attaches(state, id, entry, opts),
         :ok <- active_attach_close_result(close_results),
         :ok <- RunicSandbox.close_session(entry.session, Keyword.delete(opts, :server)) do
      {:reply, :ok, delete_entry(state, id, entry)}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:reset_session, session, opts}, _from, state) do
    case fetch_profile(state, session.sandbox) do
      {:ok, profile} ->
        case reset_entry(state, session, profile, opts) do
          {:ok, reset_session, state} -> {:reply, {:ok, reset_session}, state}
          {:error, error, state} -> {:reply, {:error, error}, state}
          {:error, error} -> {:reply, {:error, error}, state}
        end

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:acquire_lease, session, resource, opts}, _from, state) do
    with {:ok, _id, entry} <- fetch_entry(state, session),
         :ok <- validate_entry_handle(entry, session),
         :ok <- validate_no_conflicting_lease(state, session, resource, opts),
         {:ok, lease} <- new_lease(session, resource, opts) do
      {:reply, {:ok, lease}, %{state | leases: Map.put(state.leases, lease.id, lease)}}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:release_lease, lease, _opts}, _from, state) do
    case Map.fetch(state.leases, lease.id) do
      {:ok, %Lease{} = managed} ->
        if managed.session_id == lease.session_id and managed.backend == lease.backend do
          {:reply, :ok, %{state | leases: Map.delete(state.leases, lease.id)}}
        else
          {:reply,
           {:error,
            Error.validation("sandbox lease handle does not match managed lease",
              source: __MODULE__,
              details: %{lease_id: lease.id, session_id: lease.session_id}
            )}, state}
        end

      :error ->
        {:reply,
         {:error,
          Error.validation("unknown managed sandbox lease",
            source: __MODULE__,
            details: %{lease_id: lease.id, session_id: lease.session_id}
          )}, state}
    end
  end

  def handle_call({:status, sandbox}, _from, state) do
    state = reap_all_idle(state)
    {:reply, {:ok, status_map(state, sandbox)}, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    Enum.each(state.sessions, fn {_id, entry} -> RunicSandbox.close_session(entry.session) end)
    :ok
  end

  @impl true
  def handle_info(:reap_idle, %__MODULE__{} = state) do
    {:noreply, state |> reap_all_idle() |> schedule_reaper()}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, %__MODULE__{} = state) do
    state =
      state.sessions
      |> Enum.filter(fn {_id, entry} ->
        entry.lifecycle == :checked_out and entry.monitor_ref == monitor_ref
      end)
      |> Enum.reduce(state, fn {id, entry}, state ->
        _ = RunicSandbox.close_session(entry.session)

        state
        |> delete_entry(id, %{entry | monitor_ref: nil})
        |> delete_session_leases(entry.session.id)
      end)

    {:noreply, state}
  end

  defp profiles([]) do
    profile = Profile.new!()
    {:ok, %{profile.name => profile}}
  end

  defp profiles(config) when is_list(config) do
    config
    |> Enum.reduce_while({:ok, %{}}, fn {name, profile_config}, {:ok, acc} ->
      case Profile.from_named_config(name, profile_config) do
        {:ok, profile} -> {:cont, {:ok, Map.put(acc, profile.name, profile)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp fetch_profile(%__MODULE__{profiles: profiles}, name) do
    case Map.fetch(profiles, name) do
      {:ok, %Profile{enabled?: true} = profile} ->
        {:ok, profile}

      {:ok, %Profile{} = profile} ->
        {:error,
         Error.validation("sandbox profile is disabled",
           source: __MODULE__,
           details: %{sandbox: profile.name}
         )}

      :error ->
        {:error,
         Error.validation("unknown sandbox profile",
           source: __MODULE__,
           details: %{sandbox: name, available_sandboxes: Map.keys(profiles)}
         )}
    end
  end

  defp warm_state(%__MODULE__{} = state) do
    state.profiles
    |> Map.values()
    |> Enum.reduce_while({:ok, state}, fn profile, {:ok, state} ->
      Enum.reduce_while(List.duplicate(:warm, profile.pool.warm), {:ok, state}, fn _index,
                                                                                   {:ok, state} ->
        case open_pooled_session(state, profile, [], :idle) do
          {:ok, _session, state} -> {:cont, {:ok, state}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp checkout_session(%__MODULE__{} = state, %Profile{} = profile, spec, owner_pid \\ nil) do
    state = reap_idle(state, profile)

    case idle_entry(state, profile) do
      {id, entry} ->
        state = update_entry(state, id, entry, :checked_out, owner_pid)
        {:ok, entry.session, state}

      nil ->
        if pool_size(state, profile) < profile.pool.max do
          open_pooled_session(state, profile, spec, :checked_out, owner_pid)
        else
          {:error,
           Error.validation("sandbox session pool is exhausted",
             source: __MODULE__,
             details: %{
               sandbox: profile.name,
               max: profile.pool.max,
               checkout_timeout_ms: profile.pool.checkout_timeout_ms
             },
             retryable?: true
           )}
        end
    end
  end

  defp checkin_session(%__MODULE__{} = state, %Session{} = session, %Profile{} = profile, opts) do
    with {:ok, id, entry} <- fetch_entry(state, session),
         :ok <- validate_entry_handle(entry, session),
         :ok <- validate_no_active_leases(state, session),
         :ok <- validate_no_active_attaches(entry, session) do
      if Keyword.get(opts, :reset?, profile.pool.reset_on_checkin?) do
        case reset_entry(state, entry.session, profile, opts) do
          {:ok, _session, state} -> {:ok, state}
          {:error, error, state} -> {:error, error, state}
          {:error, error} -> {:error, error}
        end
      else
        {:ok, update_entry(state, id, entry, :idle)}
      end
    end
  end

  defp reset_entry(%__MODULE__{} = state, %Session{} = session, %Profile{} = profile, opts) do
    with {:ok, id, entry} <- fetch_entry(state, session),
         :ok <- validate_entry_handle(entry, session),
         :ok <- validate_no_active_leases(state, session),
         :ok <- validate_no_active_attaches(entry, session) do
      case RunicSandbox.close_session(entry.session, Keyword.delete(opts, :server)) do
        :ok ->
          state = delete_entry(state, id, entry)

          case open_pooled_session(state, profile, [], :idle) do
            {:ok, reset_session, state} -> {:ok, reset_session, state}
            {:error, error} -> {:error, error, state}
          end

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp reply_after_checkin(success_reply, {:ok, state}, _fallback_state),
    do: {:reply, success_reply, state}

  defp reply_after_checkin(_success_reply, {:error, error, state}, _fallback_state),
    do: {:reply, {:error, error}, state}

  defp reply_after_checkin(_success_reply, {:error, error}, fallback_state),
    do: {:reply, {:error, error}, fallback_state}

  defp open_pooled_session(
         %__MODULE__{} = state,
         %Profile{} = profile,
         spec,
         lifecycle,
         owner_pid \\ nil
       ) do
    with {:ok, session} <- RunicSandbox.open_session(profile.name, spec, profile: profile) do
      {:ok, session, put_session(state, profile, session, lifecycle, owner_pid)}
    end
  end

  defp put_session(
         %__MODULE__{} = state,
         %Profile{} = profile,
         %Session{} = session,
         lifecycle,
         owner_pid
       ) do
    now = now_ms()

    entry =
      %{
        session: session,
        sandbox: profile.name,
        lifecycle: lifecycle,
        created_at_ms: now,
        last_used_at_ms: now,
        checked_out_at_ms: if(lifecycle == :checked_out, do: now, else: nil),
        active_attaches: %{}
      }
      |> Map.merge(owner_fields(lifecycle, owner_pid))

    %{state | sessions: Map.put(state.sessions, session.id, entry)}
  end

  defp update_entry(%__MODULE__{} = state, id, entry, lifecycle, owner_pid \\ nil) do
    now = now_ms()
    demonitor(entry.monitor_ref)

    entry =
      entry
      |> Map.merge(%{
        lifecycle: lifecycle,
        last_used_at_ms: now,
        checked_out_at_ms: if(lifecycle == :checked_out, do: now, else: nil),
        active_attaches: Map.get(entry, :active_attaches, %{})
      })
      |> Map.merge(owner_fields(lifecycle, owner_pid))

    %{state | sessions: Map.put(state.sessions, id, entry)}
  end

  defp delete_entry(%__MODULE__{} = state, id, entry) do
    demonitor(entry.monitor_ref)
    %{state | sessions: Map.delete(state.sessions, id)}
  end

  defp owner_fields(:checked_out, owner_pid) when is_pid(owner_pid),
    do: %{owner_pid: owner_pid, monitor_ref: Process.monitor(owner_pid)}

  defp owner_fields(_lifecycle, _owner_pid), do: %{owner_pid: nil, monitor_ref: nil}

  defp demonitor(monitor_ref) when is_reference(monitor_ref),
    do: Process.demonitor(monitor_ref, [:flush])

  defp demonitor(_monitor_ref), do: false

  defp idle_entry(%__MODULE__{} = state, %Profile{} = profile) do
    state.sessions
    |> Enum.filter(fn {_id, entry} ->
      entry.sandbox == profile.name and entry.lifecycle == :idle
    end)
    |> Enum.sort_by(fn {_id, entry} -> entry.last_used_at_ms end)
    |> List.first()
  end

  defp pool_size(%__MODULE__{} = state, %Profile{} = profile) do
    Enum.count(state.sessions, fn {_id, entry} -> entry.sandbox == profile.name end)
  end

  defp fetch_entry(%__MODULE__{} = state, %Session{} = session) do
    case Map.fetch(state.sessions, session.id) do
      {:ok, entry} -> {:ok, session.id, entry}
      :error -> unknown_session_error(session)
    end
  end

  defp validate_entry_handle(%{session: %Session{} = managed}, %Session{} = provided) do
    if managed.authority == provided.authority and managed.backend == provided.backend and
         managed.sandbox == provided.sandbox do
      :ok
    else
      {:error,
       Error.validation("sandbox session handle does not match managed pool entry",
         source: __MODULE__,
         details: %{session_id: provided.id, backend: provided.backend}
       )}
    end
  end

  defp validate_attach_handle(%{session: %Session{} = session}, %AttachHandle{} = handle) do
    if handle.session_id == session.id and handle.backend == session.backend do
      :ok
    else
      {:error,
       Error.validation("sandbox attach handle does not match managed session",
         source: __MODULE__,
         details: %{
           session_id: session.id,
           attach_session_id: handle.session_id,
           backend: session.backend,
           attach_backend: handle.backend
         }
       )}
    end
  end

  defp validate_no_conflicting_lease(%__MODULE__{} = state, %Session{} = session, resource, opts) do
    mode = Keyword.get(opts, :mode, :exclusive)
    resource = to_string(resource)

    conflict? =
      Enum.any?(state.leases, fn {_id, lease} ->
        lease.session_id == session.id and lease.resource == resource and
          (lease.mode == :exclusive or mode == :exclusive)
      end)

    if conflict? do
      {:error,
       Error.validation("sandbox lease conflicts with an active lease",
         source: __MODULE__,
         details: %{session_id: session.id, resource: resource, mode: mode},
         retryable?: true
       )}
    else
      :ok
    end
  end

  defp validate_no_active_leases(%__MODULE__{} = state, %Session{} = session) do
    active =
      state.leases
      |> Map.values()
      |> Enum.filter(&(&1.session_id == session.id))

    case active do
      [] ->
        :ok

      leases ->
        {:error,
         Error.validation("sandbox session has active leases",
           source: __MODULE__,
           details: %{session_id: session.id, lease_ids: Enum.map(leases, & &1.id)}
         )}
    end
  end

  defp validate_no_active_attaches(entry, %Session{} = session) do
    active_attaches =
      entry
      |> Map.get(:active_attaches, %{})
      |> Map.values()

    case active_attaches do
      [] ->
        :ok

      attaches ->
        {:error,
         Error.validation("sandbox session has active attaches",
           source: __MODULE__,
           details: %{session_id: session.id, attach_ids: Enum.map(attaches, & &1.id)}
         )}
    end
  end

  defp put_active_attach(%__MODULE__{} = state, id, entry, %AttachHandle{} = handle) do
    attach = attach_snapshot(handle)
    active_attaches = entry |> Map.get(:active_attaches, %{}) |> Map.put(handle.id, attach)
    entry = Map.put(entry, :active_attaches, active_attaches)
    %{state | sessions: Map.put(state.sessions, id, entry)}
  end

  defp delete_active_attach(%__MODULE__{} = state, id, entry, %AttachHandle{} = handle) do
    active_attaches = entry |> Map.get(:active_attaches, %{}) |> Map.delete(handle.id)
    entry = Map.put(entry, :active_attaches, active_attaches)
    %{state | sessions: Map.put(state.sessions, id, entry)}
  end

  defp fetch_active_attach(%__MODULE__{} = state, %AttachHandle{} = handle) do
    Enum.find_value(state.sessions, :not_found, fn {id, entry} ->
      active_attaches = Map.get(entry, :active_attaches, %{})

      if Map.has_key?(active_attaches, handle.id) do
        {:ok, id, entry}
      else
        false
      end
    end)
  end

  defp managed_attach_handle(%AttachHandle{} = handle, manager) do
    events =
      Stream.transform(
        handle.events,
        fn -> :ok end,
        fn event, acc -> {[event], acc} end,
        fn _acc ->
          _ = close_attach(manager, handle, [])
          :ok
        end
      )

    %{handle | events: events}
  end

  defp close_entry_attaches(%__MODULE__{} = state, id, entry, opts) do
    results =
      entry
      |> Map.get(:active_attaches, %{})
      |> Map.values()
      |> Enum.map(fn attach ->
        RunicSandbox.close_attach(attach.handle, Keyword.delete(opts, :server))
      end)

    entry = Map.put(entry, :active_attaches, %{})
    {results, %{state | sessions: Map.put(state.sessions, id, entry)}}
  end

  defp active_attach_close_result(results) do
    Enum.find(results, &match?({:error, _error}, &1)) || :ok
  end

  defp attach_snapshot(%AttachHandle{} = handle) do
    %{
      id: handle.id,
      session_id: handle.session_id,
      backend: handle.backend,
      status: handle.status,
      metadata: handle.metadata,
      opened_at_ms: now_ms(),
      handle: handle
    }
  end

  defp new_lease(%Session{} = session, resource, opts) do
    Lease.new(
      id: "#{session.id}:lease-#{System.unique_integer([:positive])}",
      session_id: session.id,
      backend: session.backend,
      resource: to_string(resource),
      mode: Keyword.get(opts, :mode, :exclusive),
      status: :active,
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    )
  end

  defp reap_all_idle(%__MODULE__{} = state) do
    Enum.reduce(state.profiles, state, fn {_name, profile}, state -> reap_idle(state, profile) end)
  end

  defp schedule_reaper(%__MODULE__{} = state) do
    case next_reaper_interval_ms(state) do
      nil ->
        %{state | reaper_ref: nil}

      interval_ms ->
        if is_reference(state.reaper_ref) do
          Process.cancel_timer(state.reaper_ref)
        end

        %{state | reaper_ref: Process.send_after(self(), :reap_idle, interval_ms)}
    end
  end

  defp next_reaper_interval_ms(%__MODULE__{} = state) do
    state.profiles
    |> Map.values()
    |> Enum.map(& &1.pool.idle_ttl_ms)
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> nil
      value -> max(value, 1)
    end
  end

  defp reap_idle(%__MODULE__{} = state, %Profile{pool: %{idle_ttl_ms: :infinity}}), do: state

  defp reap_idle(%__MODULE__{} = state, %Profile{} = profile) do
    now = now_ms()

    expired =
      state.sessions
      |> Enum.filter(fn {_id, entry} ->
        entry.sandbox == profile.name and entry.lifecycle == :idle and
          now - entry.last_used_at_ms >= profile.pool.idle_ttl_ms
      end)
      |> Enum.sort_by(fn {_id, entry} -> entry.last_used_at_ms end)

    removable = max(length(expired) - profile.pool.warm, 0)

    expired
    |> Enum.take(removable)
    |> Enum.reduce(state, fn {id, entry}, state ->
      _ = RunicSandbox.close_session(entry.session)
      delete_entry(state, id, entry)
    end)
  end

  defp delete_session_leases(%__MODULE__{} = state, session_id) do
    leases =
      Map.reject(state.leases, fn {_id, lease} -> lease.session_id == session_id end)

    %{state | leases: leases}
  end

  defp unknown_session_error(%Session{} = session) do
    {:error,
     Error.validation("unknown managed sandbox session",
       source: __MODULE__,
       details: %{session_id: session.id, backend: session.backend}
     )}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp status_map(
         %__MODULE__{
           profiles: profiles,
           instances: instances,
           sessions: sessions,
           leases: leases
         },
         sandbox
       ) do
    selected =
      case sandbox do
        nil -> profiles
        sandbox -> Map.take(profiles, [sandbox])
      end

    %{
      status: :available,
      sandboxes:
        Map.new(selected, fn {name, profile} ->
          {name,
           %{
             backend: profile.backend,
             runtimes: profile.runtimes,
             isolation_level: profile.isolation_level,
             network: profile.policy.network,
             stateful?: profile.stateful?,
             workspace: profile.workspace,
             pool: profile.pool,
             metadata: profile.metadata,
             instance: Map.get(instances, name),
             sessions:
               sessions
               |> Map.values()
               |> Enum.filter(&(&1.sandbox == name))
               |> Enum.map(fn entry ->
                 entry.session
                 |> Map.take([:id, :state, :state_model, :transport_model])
                 |> Map.merge(%{
                   lifecycle: entry.lifecycle,
                   created_at_ms: entry.created_at_ms,
                   last_used_at_ms: entry.last_used_at_ms,
                   checked_out_at_ms: entry.checked_out_at_ms,
                   owner_alive?: is_pid(entry.owner_pid) and Process.alive?(entry.owner_pid),
                   active_attach_count: entry |> Map.get(:active_attaches, %{}) |> map_size(),
                   active_attaches:
                     entry
                     |> Map.get(:active_attaches, %{})
                     |> Map.values()
                     |> Enum.map(&Map.drop(&1, [:handle]))
                 })
               end)
               |> Enum.map(fn session ->
                 Map.put(
                   session,
                   :active_leases,
                   leases |> Map.values() |> Enum.count(&(&1.session_id == session.id))
                 )
               end)
           }}
        end)
    }
  end
end
