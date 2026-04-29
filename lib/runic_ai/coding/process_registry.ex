defmodule RunicAI.Coding.ProcessRegistry do
  @moduledoc """
  Opt-in background process registry for coding harnesses.
  """

  use GenServer

  alias RunicAI.Coding.Command
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.ProcessHandle
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @default_log_bytes 131_072

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    {:ok, %{processes: %{}, max_log_bytes: Keyword.get(opts, :max_log_bytes, @default_log_bytes)}}
  end

  @spec start_process(server(), Workspace.t(), Command.t() | keyword() | map(), keyword()) ::
          {:ok, ProcessHandle.t()} | {:error, Error.t()}
  def start_process(server, %Workspace{} = workspace, command_input, opts \\ []) do
    policy_input = Keyword.get(opts, :policy)

    with {:ok, command} <- Command.from_input(command_input),
         {:ok, policy} <- CommandPolicy.from_input(policy_input),
         {:ok, authorization} <- CommandPolicy.authorize(policy, workspace, command) do
      GenServer.call(server, {:start_process, command, authorization})
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @spec poll(server(), String.t()) :: {:ok, ProcessHandle.t()} | {:error, Error.t()}
  def poll(server, id), do: GenServer.call(server, {:poll, id})

  @spec log(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def log(server, id, opts \\ []), do: GenServer.call(server, {:log, id, opts})

  @spec write(server(), String.t(), binary()) :: :ok | {:error, Error.t()}
  def write(server, id, input) when is_binary(input),
    do: GenServer.call(server, {:write, id, input})

  @spec kill(server(), String.t()) :: {:ok, ProcessHandle.t()} | {:error, Error.t()}
  def kill(server, id), do: GenServer.call(server, {:kill, id})

  @impl true
  def handle_call({:start_process, command, authorization}, _from, state) do
    id = "proc-" <> Integer.to_string(System.unique_integer([:positive]))
    started_at = DateTime.utc_now()

    with {:ok, port} <- open_port(command, authorization),
         handle <-
           ProcessHandle.new!(
             id: id,
             command: Command.display(command),
             argv: command.argv,
             cwd: authorization.cwd,
             status: :running,
             started_at: started_at,
             updated_at: started_at,
             metadata: %{backend: command.backend}
           ) do
      process = %{port: port, handle: handle, log: "", killed?: false}
      {:reply, {:ok, handle}, put_in(state.processes[id], process)}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:poll, id}, _from, state) do
    with {:ok, process} <- fetch_process(state, id) do
      {:reply, {:ok, process.handle}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:log, id, opts}, _from, state) do
    with {:ok, process} <- fetch_process(state, id) do
      max_bytes = Keyword.get(opts, :max_bytes, state.max_log_bytes)
      output = truncate_tail(process.log, max_bytes)

      {:reply,
       {:ok,
        %{
          id: id,
          output: output,
          output_bytes: byte_size(process.log),
          truncated?: byte_size(output) < byte_size(process.log),
          status: process.handle.status
        }}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:write, id, input}, _from, state) do
    with {:ok, process} <- fetch_process(state, id),
         :ok <- ensure_running(process.handle),
         true <- Port.command(process.port, input) do
      {:reply, :ok, state}
    else
      false ->
        {:reply,
         {:error,
          Error.new(:process_write_failed, "could not write to process", source: __MODULE__)},
         state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:kill, id}, _from, state) do
    with {:ok, process} <- fetch_process(state, id) do
      if process.handle.status == :running do
        Port.close(process.port)
      end

      handle = ProcessHandle.update(process.handle, status: :killed)
      process = %{process | handle: handle, killed?: true}
      {:reply, {:ok, handle}, put_in(state.processes[id], process)}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, state) do
    {:noreply, append_log_by_port(state, port, data)}
  end

  def handle_info({port, {:exit_status, status}}, state) do
    {:noreply, mark_exit_by_port(state, port, status)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp open_port(%Command{backend: :argv, argv: [executable | args]}, authorization) do
    port =
      Port.open({:spawn_executable, System.find_executable(executable) || executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:cd, authorization.cwd},
        {:env, authorization.env}
      ])

    {:ok, port}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp open_port(%Command{backend: :shell, shell: shell}, authorization) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh") || "sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["-c", shell]},
        {:cd, authorization.cwd},
        {:env, authorization.env}
      ])

    {:ok, port}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp append_log_by_port(state, nil, _data), do: state

  defp append_log_by_port(state, port, data) do
    update_process_by_port(state, port, fn process ->
      log = truncate_tail(process.log <> data, state.max_log_bytes)
      %{process | log: log}
    end)
  end

  defp mark_exit_by_port(state, port, status) do
    update_process_by_port(state, port, fn process ->
      handle =
        ProcessHandle.update(process.handle,
          status: if(process.killed?, do: :killed, else: :exited),
          exit_status: status
        )

      %{process | handle: handle}
    end)
  end

  defp update_process_by_port(state, port, fun) do
    case find_process_entry_by_port(state, port) do
      {id, process} ->
        put_in(state.processes[id], fun.(process))

      nil ->
        state
    end
  end

  defp find_process_entry_by_port(state, port) do
    Enum.find(state.processes, fn {_id, process} -> process.port == port end)
  end

  defp fetch_process(state, id) when is_binary(id) do
    case Map.fetch(state.processes, id) do
      {:ok, process} ->
        {:ok, process}

      :error ->
        {:error,
         Error.validation("unknown process id",
           source: __MODULE__,
           details: %{id: id}
         )}
    end
  end

  defp ensure_running(%ProcessHandle{status: :running}), do: :ok

  defp ensure_running(%ProcessHandle{} = handle) do
    {:error,
     Error.validation("process is not running",
       source: __MODULE__,
       details: %{id: handle.id, status: handle.status}
     )}
  end

  defp truncate_tail(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp truncate_tail(binary, max_bytes) do
    start = byte_size(binary) - max_bytes
    binary_part(binary, start, max_bytes)
  end
end
