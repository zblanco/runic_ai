defmodule RunicAI.Coding.SandboxSessionRegistry do
  @moduledoc """
  Process-owned registry for model-visible sandbox sessions.

  RunicSandbox session handles are signed and manager-owned. This registry keeps
  the actual handle inside a long-lived process and exposes only opaque ids to
  tools, so later model-visible calls can operate on the same sandbox session
  without serializing backend authority data.
  """

  use GenServer

  alias RunicAI.Error
  alias RunicSandbox, as: Sandbox
  alias RunicSandbox.Checkpoint
  alias RunicSandbox.ExecutionResult
  alias RunicSandbox.FileRef
  alias RunicSandbox.ProcessHandle, as: SandboxProcessHandle
  alias RunicSandbox.ProcessStatus
  alias RunicSandbox.Proxy
  alias RunicSandbox.Service
  alias RunicSandbox.Session

  defstruct sessions: %{}, processes: %{}, proxies: %{}

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec open_session(server(), atom(), keyword() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def open_session(server, sandbox, spec \\ [], opts \\ []) do
    GenServer.call(server, {:open_session, sandbox, spec, opts}, :infinity)
  end

  @spec exec(server(), String.t(), keyword() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def exec(server, id, request, opts \\ []) do
    GenServer.call(server, {:exec, id, request, opts}, :infinity)
  end

  @spec write_file(server(), String.t(), Path.t(), iodata(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def write_file(server, id, path, contents, opts \\ []) do
    GenServer.call(server, {:write_file, id, path, contents, opts}, :infinity)
  end

  @spec read_file(server(), String.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def read_file(server, id, path, opts \\ []) do
    GenServer.call(server, {:read_file, id, path, opts}, :infinity)
  end

  @spec list_files(server(), String.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def list_files(server, id, path \\ ".", opts \\ []) do
    GenServer.call(server, {:list_files, id, path, opts}, :infinity)
  end

  @spec checkpoint(server(), String.t(), keyword() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def checkpoint(server, id, spec \\ [], opts \\ []) do
    GenServer.call(server, {:checkpoint, id, spec, opts}, :infinity)
  end

  @spec restore(server(), String.t(), Checkpoint.t() | String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def restore(server, id, checkpoint, opts \\ []) do
    GenServer.call(server, {:restore, id, checkpoint, opts}, :infinity)
  end

  @spec close_session(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def close_session(server, id, opts \\ []) do
    GenServer.call(server, {:close_session, id, opts}, :infinity)
  end

  @spec start_process(server(), String.t(), keyword() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def start_process(server, id, request, opts \\ []) do
    GenServer.call(server, {:start_process, id, request, opts}, :infinity)
  end

  @spec list_processes(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_processes(server, id, opts \\ []) do
    GenServer.call(server, {:list_processes, id, opts}, :infinity)
  end

  @spec process_status(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def process_status(server, process_id, opts \\ []) do
    GenServer.call(server, {:process_status, process_id, opts}, :infinity)
  end

  @spec process_events(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def process_events(server, process_id, opts \\ []) do
    GenServer.call(server, {:process_events, process_id, opts}, :infinity)
  end

  @spec write_process_stdin(server(), String.t(), iodata(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def write_process_stdin(server, process_id, input, opts \\ []) do
    GenServer.call(server, {:write_process_stdin, process_id, input, opts}, :infinity)
  end

  @spec close_process_stdin(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def close_process_stdin(server, process_id, opts \\ []) do
    GenServer.call(server, {:close_process_stdin, process_id, opts}, :infinity)
  end

  @spec signal_process(server(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def signal_process(server, process_id, signal, opts \\ []) do
    GenServer.call(server, {:signal_process, process_id, signal, opts}, :infinity)
  end

  @spec kill_process(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def kill_process(server, process_id, opts \\ []) do
    GenServer.call(server, {:kill_process, process_id, opts}, :infinity)
  end

  @spec wait_process(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def wait_process(server, process_id, opts \\ []) do
    GenServer.call(server, {:wait_process, process_id, opts}, :infinity)
  end

  @spec start_service(server(), String.t(), keyword() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def start_service(server, id, spec, opts \\ []) do
    GenServer.call(server, {:start_service, id, spec, opts}, :infinity)
  end

  @spec stop_service(server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def stop_service(server, id, service_id, opts \\ []) do
    GenServer.call(server, {:stop_service, id, service_id, opts}, :infinity)
  end

  @spec list_services(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_services(server, id, opts \\ []) do
    GenServer.call(server, {:list_services, id, opts}, :infinity)
  end

  @spec open_proxy(server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def open_proxy(server, id, service_id, opts \\ []) do
    GenServer.call(server, {:open_proxy, id, service_id, opts}, :infinity)
  end

  @spec close_proxy(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def close_proxy(server, proxy_id, opts \\ []) do
    GenServer.call(server, {:close_proxy, proxy_id, opts}, :infinity)
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:open_session, sandbox, spec, opts}, _from, state) do
    with {:ok, session} <- Sandbox.open_session(sandbox, spec, opts) |> normalize_sandbox_result() do
      id = "sandbox_session_#{System.unique_integer([:positive])}"
      entry = %{id: id, session: session, opts: opts, opened_at: DateTime.utc_now()}
      {:reply, {:ok, session_snapshot(entry)}, put_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:exec, id, request, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, result} <- Sandbox.exec(entry.session, request, opts) |> normalize_sandbox_result() do
      {:reply, {:ok, execution_result_snapshot(result, entry)}, touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:write_file, id, path, contents, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, ref} <-
           Sandbox.write_file(entry.session, path, contents, opts) |> normalize_sandbox_result() do
      {:reply, {:ok, Map.put(file_ref_snapshot(ref), :session, session_snapshot(entry))},
       touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:read_file, id, path, opts}, _from, state) do
    max_bytes = Keyword.get(opts, :max_bytes, 16_384)

    with {:ok, entry} <- fetch_session(state, id),
         {:ok, content} <-
           Sandbox.read_file(entry.session, path, opts) |> normalize_sandbox_result() do
      preview = binary_part(content, 0, min(byte_size(content), max_bytes))

      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          path: path,
          content: preview,
          byte_size: byte_size(content),
          truncated?: byte_size(content) > byte_size(preview)
        }}, touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:list_files, id, path, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, refs} <-
           Sandbox.list_files(entry.session, path, opts) |> normalize_sandbox_result() do
      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          path: path,
          files: Enum.map(refs, &file_ref_snapshot/1),
          count: length(refs)
        }}, touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:checkpoint, id, spec, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, checkpoint} <-
           Sandbox.checkpoint(entry.session, spec, opts) |> normalize_sandbox_result() do
      {:reply,
       {:ok, %{session: session_snapshot(entry), checkpoint: checkpoint_snapshot(checkpoint)}},
       touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:restore, id, checkpoint, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, session} <-
           Sandbox.restore(entry.session, checkpoint, opts) |> normalize_sandbox_result() do
      entry = %{entry | session: session}
      {:reply, {:ok, session_snapshot(entry)}, put_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:close_session, id, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id) do
      case Sandbox.close_session(entry.session, Keyword.merge(entry.opts, opts))
           |> normalize_sandbox_result() do
        :ok ->
          {:reply, {:ok, %{id: id, status: :closed}}, delete_session_with_processes(state, id)}

        {:error, %Error{} = error} ->
          if stale_authority_error?(error) do
            {:reply, {:ok, %{id: id, status: :closed, stale?: true}},
             delete_session_with_processes(state, id)}
          else
            {:reply, {:error, error}, state}
          end
      end
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:start_process, id, request, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, handle} <-
           Sandbox.start_process(entry.session, request, opts) |> normalize_sandbox_result() do
      process_id = "sandbox_process_#{System.unique_integer([:positive])}"

      process = %{
        id: process_id,
        session_id: id,
        handle: handle,
        opened_at: DateTime.utc_now()
      }

      state =
        state
        |> touch_session(entry)
        |> put_process(process)

      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          process: process_handle_snapshot(handle, process)
        }}, state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:list_processes, id, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, statuses} <-
           Sandbox.list_processes(entry.session, opts) |> normalize_sandbox_result() do
      processes = Enum.map(statuses, &process_status_snapshot_for_session(&1, state, id))

      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          processes: processes,
          count: length(processes)
        }}, touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:process_status, process_id, opts}, _from, state) do
    with {:ok, process} <- fetch_process(state, process_id),
         {:ok, entry} <- fetch_session(state, process.session_id),
         {:ok, status} <-
           Sandbox.process_status(entry.session, process.handle, opts)
           |> normalize_sandbox_result() do
      {:reply,
       {:ok,
        %{session: session_snapshot(entry), process: process_status_snapshot(status, process)}},
       touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:process_events, process_id, opts}, _from, state) do
    max_events = Keyword.get(opts, :max_events, 100)
    max_chunk_bytes = Keyword.get(opts, :max_chunk_bytes, 4_096)

    with {:ok, process} <- fetch_process(state, process_id),
         {:ok, entry} <- fetch_session(state, process.session_id),
         {:ok, events} <-
           Sandbox.process_events(process.handle, opts) |> normalize_sandbox_result() do
      snapshots =
        events
        |> Enum.take(max_events)
        |> Enum.map(&session_event_snapshot(&1, max_chunk_bytes))

      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          process: process_handle_snapshot(process.handle, process),
          events: snapshots,
          count: length(snapshots)
        }}, touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:write_process_stdin, process_id, input, opts}, _from, state) do
    with {:ok, process} <- fetch_process(state, process_id),
         {:ok, entry} <- fetch_session(state, process.session_id),
         :ok <-
           Sandbox.write_process_stdin(process.handle, input, opts) |> normalize_sandbox_result() do
      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          process: process_handle_snapshot(process.handle, process),
          input_bytes: IO.iodata_length(input),
          status: :written
        }}, touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:close_process_stdin, process_id, opts}, _from, state) do
    with {:ok, process} <- fetch_process(state, process_id),
         {:ok, entry} <- fetch_session(state, process.session_id),
         :ok <- Sandbox.close_process_stdin(process.handle, opts) |> normalize_sandbox_result() do
      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          process: process_handle_snapshot(process.handle, process),
          status: :stdin_closed
        }}, touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:signal_process, process_id, signal, opts}, _from, state) do
    with {:ok, process} <- fetch_process(state, process_id),
         {:ok, entry} <- fetch_session(state, process.session_id),
         :ok <-
           Sandbox.signal_process(process.handle, signal, opts) |> normalize_sandbox_result() do
      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          process: process_handle_snapshot(process.handle, process),
          signal: signal,
          status: :signaled
        }}, touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:kill_process, process_id, opts}, _from, state) do
    with {:ok, process} <- fetch_process(state, process_id),
         {:ok, entry} <- fetch_session(state, process.session_id),
         :ok <- Sandbox.kill_process(process.handle, opts) |> normalize_sandbox_result() do
      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          process: process_handle_snapshot(process.handle, process),
          status: :killed
        }}, state |> touch_session(entry) |> delete_process(process_id)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:wait_process, process_id, opts}, _from, state) do
    with {:ok, process} <- fetch_process(state, process_id),
         {:ok, entry} <- fetch_session(state, process.session_id),
         {:ok, status} <- Sandbox.wait_process(process.handle, opts) |> normalize_sandbox_result() do
      process = %{process | handle: %{process.handle | status: status.status}}

      state =
        state
        |> touch_session(entry)
        |> put_process(process)

      {:reply,
       {:ok,
        %{session: session_snapshot(entry), process: process_status_snapshot(status, process)}},
       state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:start_service, id, spec, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, service} <-
           Sandbox.start_service(entry.session, spec, opts) |> normalize_sandbox_result() do
      {:reply, {:ok, %{session: session_snapshot(entry), service: service_snapshot(service)}},
       touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:stop_service, id, service_id, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         :ok <-
           Sandbox.stop_service(entry.session, service_id, opts) |> normalize_sandbox_result() do
      {:reply,
       {:ok, %{session: session_snapshot(entry), service_id: service_id, status: :stopped}},
       touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:list_services, id, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, services} <-
           Sandbox.list_services(entry.session, opts) |> normalize_sandbox_result() do
      {:reply,
       {:ok,
        %{
          session: session_snapshot(entry),
          services: Enum.map(services, &service_snapshot/1),
          count: length(services)
        }}, touch_session(state, entry)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:open_proxy, id, service_id, opts}, _from, state) do
    with {:ok, entry} <- fetch_session(state, id),
         {:ok, proxy} <-
           Sandbox.open_proxy(entry.session, service_id, opts) |> normalize_sandbox_result() do
      state = put_proxy(touch_session(state, entry), proxy)

      {:reply, {:ok, %{session: session_snapshot(entry), proxy: proxy_snapshot(proxy)}}, state}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:close_proxy, proxy_id, opts}, _from, state) do
    with {:ok, proxy} <- fetch_proxy(state, proxy_id),
         :ok <- Sandbox.close_proxy(proxy, opts) |> normalize_sandbox_result() do
      {:reply, {:ok, %{id: proxy_id, status: :closed}}, delete_proxy(state, proxy_id)}
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    Enum.each(state.sessions, fn {_id, entry} ->
      _ = Sandbox.close_session(entry.session, entry.opts)
    end)

    :ok
  end

  defp fetch_session(%__MODULE__{sessions: sessions}, id) when is_binary(id) do
    case Map.fetch(sessions, id) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        {:error,
         Error.validation("unknown sandbox session id",
           source: __MODULE__,
           details: %{session_id: id}
         )}
    end
  end

  defp fetch_session(_state, id) do
    {:error,
     Error.validation("sandbox session id must be a non-empty string",
       source: __MODULE__,
       details: %{session_id: id}
     )}
  end

  defp fetch_proxy(%__MODULE__{proxies: proxies}, id) when is_binary(id) do
    case Map.fetch(proxies, id) do
      {:ok, proxy} ->
        {:ok, proxy}

      :error ->
        {:error,
         Error.validation("unknown sandbox proxy id",
           source: __MODULE__,
           details: %{proxy_id: id}
         )}
    end
  end

  defp fetch_process(%__MODULE__{processes: processes}, id) when is_binary(id) do
    case Map.fetch(processes, id) do
      {:ok, process} ->
        {:ok, process}

      :error ->
        {:error,
         Error.validation("unknown sandbox process id",
           source: __MODULE__,
           details: %{process_id: id}
         )}
    end
  end

  defp fetch_process(_state, id) do
    {:error,
     Error.validation("sandbox process id must be a non-empty string",
       source: __MODULE__,
       details: %{process_id: id}
     )}
  end

  defp put_session(%__MODULE__{} = state, entry),
    do: %{state | sessions: Map.put(state.sessions, entry.id, entry)}

  defp touch_session(%__MODULE__{} = state, entry),
    do: put_session(state, Map.put(entry, :last_used_at, DateTime.utc_now()))

  defp delete_session_with_processes(%__MODULE__{} = state, id) do
    processes =
      Map.reject(state.processes, fn {_process_id, process} -> process.session_id == id end)

    %{state | sessions: Map.delete(state.sessions, id), processes: processes}
  end

  defp put_process(%__MODULE__{} = state, process),
    do: %{state | processes: Map.put(state.processes, process.id, process)}

  defp delete_process(%__MODULE__{} = state, id),
    do: %{state | processes: Map.delete(state.processes, id)}

  defp put_proxy(%__MODULE__{} = state, %Proxy{} = proxy),
    do: %{state | proxies: Map.put(state.proxies, proxy.id, proxy)}

  defp delete_proxy(%__MODULE__{} = state, id),
    do: %{state | proxies: Map.delete(state.proxies, id)}

  defp session_snapshot(%{id: id, session: %Session{} = session} = entry) do
    %{
      id: id,
      session_id: session.id,
      sandbox: session.sandbox,
      backend: session.backend,
      state: session.state,
      capabilities: Map.from_struct(session.capabilities),
      isolation_level: session.isolation_level,
      state_model: session.state_model,
      transport_model: session.transport_model,
      persistent_identity?: session.persistent_identity?,
      workspace_ref: session.workspace_ref,
      metadata: session.metadata,
      opened_at: Map.get(entry, :opened_at),
      last_used_at: Map.get(entry, :last_used_at)
    }
  end

  defp execution_result_snapshot(%ExecutionResult{} = result, entry) do
    %{
      session: session_snapshot(entry),
      status: result.status,
      stdout: result.stdout,
      stderr: result.stderr,
      exit_status: result.exit_status,
      duration_ms: result.duration_ms,
      files_changed: result.files_changed,
      artifacts: result.artifacts,
      backend: result.backend,
      isolation_level: result.isolation_level,
      diagnostics: result.diagnostics,
      resource_usage: result.resource_usage,
      metadata: result.metadata
    }
  end

  defp file_ref_snapshot(%FileRef{} = ref) do
    %{
      path: ref.path,
      kind: ref.kind,
      bytes: ref.bytes,
      sha256: ref.sha256,
      metadata: ref.metadata
    }
  end

  defp file_ref_snapshot(ref) when is_map(ref), do: ref

  defp checkpoint_snapshot(%Checkpoint{} = checkpoint) do
    %{
      id: checkpoint.id,
      session_id: checkpoint.session_id,
      backend: checkpoint.backend,
      ref: checkpoint.ref,
      created_at: checkpoint.created_at,
      metadata: checkpoint.metadata
    }
  end

  defp service_snapshot(%Service{} = service) do
    %{
      id: service.id,
      session_id: service.session_id,
      name: service.name,
      status: service.status,
      ports: service.ports,
      metadata: service.metadata
    }
  end

  defp process_handle_snapshot(%SandboxProcessHandle{} = handle, process) do
    %{
      id: process.id,
      session_id: process.session_id,
      backend: handle.backend,
      status: handle.status,
      command: handle.command,
      metadata: handle.metadata,
      opened_at: Map.get(process, :opened_at)
    }
  end

  defp process_status_snapshot_for_session(
         %ProcessStatus{} = status,
         %__MODULE__{} = state,
         session_id
       ) do
    case find_process_by_backend_id(state, session_id, status.id) do
      nil -> process_status_snapshot(status, %{id: nil, session_id: session_id}, false)
      process -> process_status_snapshot(status, process)
    end
  end

  defp process_status_snapshot(%ProcessStatus{} = status, process),
    do: process_status_snapshot(status, process, true)

  defp process_status_snapshot(%ProcessStatus{} = status, process, managed?) do
    %{
      id: process.id,
      session_id: process.session_id,
      backend: status.backend,
      status: status.status,
      pid: status.pid,
      exit_status: status.exit_status,
      started_at_ms: status.started_at_ms,
      finished_at_ms: status.finished_at_ms,
      metadata: status.metadata,
      managed?: managed?
    }
  end

  defp find_process_by_backend_id(%__MODULE__{} = state, session_id, backend_id) do
    Enum.find_value(state.processes, fn {_id, process} ->
      if process.session_id == session_id and process.handle.id == backend_id, do: process
    end)
  end

  defp session_event_snapshot(%RunicSandbox.SessionEvent{} = event, max_chunk_bytes) do
    %{
      id: event.id,
      session_id: event.session_id,
      type: event.type,
      at: event.at,
      payload: truncate_event_payload(event.payload, max_chunk_bytes),
      metadata: event.metadata
    }
  end

  defp truncate_event_payload(payload, max_chunk_bytes) when is_map(payload) do
    Map.new(payload, fn
      {key, value} when key in [:chunk, "chunk"] and is_binary(value) ->
        preview = binary_part(value, 0, min(byte_size(value), max_chunk_bytes))
        {key, preview}

      pair ->
        pair
    end)
  end

  defp truncate_event_payload(payload, _max_chunk_bytes), do: payload

  defp proxy_snapshot(%Proxy{} = proxy) do
    %{
      id: proxy.id,
      session_id: proxy.session_id,
      backend: proxy.backend,
      service_id: proxy.service_id,
      status: proxy.status,
      url: proxy.url,
      local_port: proxy.local_port,
      metadata: proxy.metadata
    }
  end

  defp normalize_sandbox_result({:ok, value}), do: {:ok, value}
  defp normalize_sandbox_result(:ok), do: :ok

  defp normalize_sandbox_result({:error, %RunicSandbox.Error{} = error}) do
    {:error,
     Error.new(error.kind, error.message,
       details: error.details,
       source: error.source,
       retryable?: error.retryable?,
       metadata: error.metadata
     )}
  end

  defp normalize_sandbox_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_sandbox_result({:error, reason}) do
    {:error, Error.from_reason(reason, source: __MODULE__)}
  end

  defp stale_authority_error?(%Error{} = error) do
    error.kind == :validation and error.message == "sandbox session authority is not active"
  end
end
