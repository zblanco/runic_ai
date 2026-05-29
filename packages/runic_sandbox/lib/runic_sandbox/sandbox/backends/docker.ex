defmodule RunicSandbox.Backends.Docker do
  @moduledoc """
  One-shot Docker CLI sandbox backend.

  The backend uses `docker run --rm` with explicit argv construction, disabled
  network by default, and a temporary copy-in workspace. It reports container
  isolation truth as metadata; Docker is useful isolation, but not a microVM.
  """

  @behaviour RunicSandbox.Backend

  alias RunicSandbox.AttachEvents
  alias RunicSandbox.AttachHandle
  alias RunicSandbox.Capabilities
  alias RunicSandbox.Checkpoint
  alias RunicSandbox.Error
  alias RunicSandbox.ExecutionRequest
  alias RunicSandbox.ExecutionResult
  alias RunicSandbox.FileRef
  alias RunicSandbox.Instance
  alias RunicSandbox.Profile
  alias RunicSandbox.Session

  @default_image "runic-ai/sandbox:elixir-python-node"
  @default_timeout_ms 30_000
  @runtime_commands %{
    bash: ["sh", "-lc"],
    sh: ["sh", "-lc"],
    python: ["python3", "-c"],
    node: ["node", "-e"],
    elixir: ["elixir", "-e"],
    lua: ["lua", "-e"]
  }

  @impl true
  def provision(%Profile{backend: backend} = profile, opts) when backend in [:docker, :gvisor] do
    metadata =
      %{
        security_boundary?: true,
        backend_module: __MODULE__,
        available?: exec_ready?(profile),
        host_available?: container_available?(profile),
        image_available?: image_available?(image(profile)),
        image: image(profile),
        container_runtime: container_runtime(profile),
        backend_options: profile.backend_options,
        stateful?: stateful?(profile)
      }
      |> maybe_put_stateful_workspace(profile)

    {:ok,
     Instance.from_profile(profile,
       id: Keyword.get(opts, :id),
       state: if(exec_ready?(profile), do: :ready, else: :unavailable),
       metadata: metadata
     )}
  end

  def provision(%Profile{} = profile, _opts) do
    {:error,
     Error.validation(
       "container backend cannot provision profile backend #{inspect(profile.backend)}",
       source: __MODULE__,
       details: %{backend: profile.backend}
     )}
  end

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{} = request, _opts) do
    started_mono = System.monotonic_time(:millisecond)

    with :ok <- ensure_container_available(instance),
         {:ok, command} <- runtime_command(request),
         :ok <- ensure_workspace_supported(instance),
         {:ok, workspace_root, cleanup?} <- prepare_workspace(instance, request) do
      exec_in_workspace(instance, request, command, workspace_root, cleanup?, started_mono)
    end
  end

  defp exec_in_workspace(instance, request, command, workspace_root, cleanup?, started_mono) do
    try do
      with {:ok, before_files} <- snapshot_files(workspace_root),
           {:ok, output, exit_status, timed_out?} <-
             run_container(instance, request, command, workspace_root),
           {:ok, after_files} <- snapshot_files(workspace_root),
           {:ok, files_changed, artifacts} <-
             workspace_delta(workspace_root, before_files, after_files, request.max_output_bytes) do
        duration_ms = System.monotonic_time(:millisecond) - started_mono
        {stdout, stderr} = split_output(output)

        ExecutionResult.new(
          status: status(exit_status, timed_out?),
          stdout: cap(stdout, request.max_output_bytes),
          stderr: cap(stderr, request.max_output_bytes),
          exit_status: exit_status,
          duration_ms: duration_ms,
          files_changed: files_changed,
          artifacts: artifacts,
          backend: instance.backend,
          isolation_level: instance.isolation_level,
          diagnostics: diagnostics(output, request.max_output_bytes, timed_out?),
          resource_usage: %{},
          metadata: %{
            sandbox: request.sandbox,
            runtime: request.runtime,
            mode: request.mode,
            network: request.network,
            image: image(instance),
            workspace_mode: instance.workspace.mode,
            workspace_mount: instance.workspace.mount,
            stateful?: stateful_instance?(instance),
            container_runtime: option(instance.metadata, :container_runtime),
            security_boundary?: true
          }
        )
      end
    after
      if cleanup?, do: File.rm_rf(workspace_root)
    end
  end

  @impl true
  def upload(%Instance{}, _files, _opts) do
    {:error,
     Error.validation("docker backend persistent upload is not supported", source: __MODULE__)}
  end

  @impl true
  def download(%Instance{}, _paths, _opts) do
    {:error,
     Error.validation("docker backend persistent download is not supported", source: __MODULE__)}
  end

  @impl true
  def snapshot(%Instance{} = instance, _opts) do
    {:ok,
     %{
       instance_id: instance.id,
       backend: instance.backend,
       stateful?: stateful_instance?(instance),
       container_runtime: option(instance.metadata, :container_runtime)
     }}
  end

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{} = instance, _opts) do
    case option(instance.metadata, :workspace_root) do
      nil -> :ok
      workspace_root -> File.rm_rf(workspace_root)
    end
  end

  @impl true
  def health(opts) do
    profile = Keyword.get(opts, :profile)
    backend = if(profile, do: profile.backend, else: :docker)
    configured_image = image(profile)
    docker_available? = docker_available?()
    runsc_available? = runsc_available?()
    docker_runsc_runtime_available? = docker_runsc_runtime_available?()
    host_available? = container_available?(profile)
    image_available? = image_available?(configured_image)
    exec_ready? = host_available? and image_available?

    {:ok,
     %{
       name: backend,
       available?: exec_ready?,
       host_available?: host_available?,
       configured?: true,
       exec_ready?: exec_ready?,
       docker_available?: docker_available?,
       runsc_available?: runsc_available?,
       docker_runsc_runtime_available?: docker_runsc_runtime_available?,
       container_runtime: container_runtime(profile),
       image: configured_image,
       image_available?: image_available?,
       runtimes: [:bash, :sh, :python, :node, :elixir, :lua],
       isolation_level: isolation_level(backend),
       network: %{default: :disabled},
       stateful?: if(profile, do: stateful?(profile), else: false),
       security_boundary?: true,
       capabilities:
         Capabilities.to_map(
           Capabilities.new!(
             exec?: true,
             files?: false,
             inline_files?: true,
             artifacts?: true,
             session_files?: true,
             checkpoints?: true,
             services?: false,
             proxy?: false,
             leases?: false,
             streaming?: true,
             network_policy?: true,
             persistent_identity?: if(profile, do: stateful?(profile), else: false)
           )
         ),
       missing_requirements:
         docker_missing_requirements(
           backend,
           docker_available?,
           docker_runsc_runtime_available?,
           image_available?
         ),
       diagnostics:
         health_diagnostics(
           backend,
           docker_available?,
           docker_runsc_runtime_available?,
           image_available?,
           configured_image
         )
     }}
  end

  @impl true
  def open_session(%Profile{backend: backend} = profile, opts)
      when backend in [:docker, :gvisor] do
    session_profile = persistent_profile(profile)

    with {:ok, instance} <- provision(session_profile, opts),
         :ok <- ensure_container_available(instance),
         {:ok, workspace_root} <- session_workspace_root(instance),
         :ok <- File.mkdir_p(workspace_root) do
      Session.from_instance(instance,
        capabilities:
          Capabilities.new!(
            exec?: true,
            files?: true,
            inline_files?: true,
            artifacts?: true,
            session_files?: true,
            checkpoints?: true,
            services?: false,
            proxy?: false,
            leases?: false,
            streaming?: true,
            network_policy?: true,
            persistent_identity?: true
          ),
        policy: session_profile.policy,
        state_model: :persistent_workspace,
        transport_model: if(backend == :gvisor, do: :docker_cli, else: :docker_cli),
        persistent_identity?: true,
        workspace_ref: "workspace://#{instance.id}",
        metadata: %{workspace_root: workspace_root}
      )
    end
  end

  @impl true
  def close_session(%Session{} = session, _opts) do
    case session_workspace_root(session) do
      {:ok, workspace_root} ->
        File.rm_rf(workspace_root)
        :ok

      {:error, _error} ->
        :ok
    end
  end

  @impl true
  def exec_session(
        %Session{instance: %Instance{} = instance},
        %ExecutionRequest{} = request,
        opts
      ) do
    exec(instance, request, opts)
  end

  @impl true
  def attach_session(
        %Session{instance: %Instance{} = instance} = session,
        %ExecutionRequest{} = request,
        _opts
      ) do
    with :ok <- ensure_container_available(instance),
         {:ok, command} <- runtime_command(request),
         :ok <- ensure_workspace_supported(instance),
         {:ok, workspace_root, cleanup?} <- prepare_workspace(instance, request),
         {:ok, before_files} <- snapshot_files(workspace_root),
         {:ok, handle} <-
           open_container_attach(
             session,
             instance,
             request,
             command,
             workspace_root,
             cleanup?,
             before_files
           ) do
      {:ok, handle}
    end
  end

  @impl true
  def write_stdin(%AttachHandle{metadata: metadata}, input, _opts) do
    case Map.get(metadata, :port) do
      port when is_port(port) ->
        Port.command(port, IO.iodata_to_binary(input))
        :ok

      _other ->
        {:error,
         Error.validation("docker attach handle is not writable",
           source: __MODULE__,
           details: %{backend: :docker}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @impl true
  def close_attach(%AttachHandle{metadata: metadata}, _opts) do
    cleanup_attach(metadata)
    :ok
  end

  @impl true
  def write_file(%Session{} = session, path, contents, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, full_path} <- safe_workspace_path(workspace_root, path),
         :ok <- ensure_no_symlink_path(workspace_root, full_path),
         :ok <- File.mkdir_p(Path.dirname(full_path)),
         :ok <- File.write(full_path, contents),
         {:ok, ref} <- file_ref(workspace_root, full_path) do
      {:ok, ref}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to write docker session file"
         )}
    end
  end

  @impl true
  def read_file(%Session{} = session, path, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, full_path} <- safe_workspace_path(workspace_root, path),
         :ok <- ensure_no_symlink_path(workspace_root, full_path),
         :ok <- ensure_regular_file(full_path) do
      File.read(full_path)
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to read docker session file"
         )}
    end
  end

  @impl true
  def list_files(%Session{} = session, path, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, full_path} <- safe_workspace_path(workspace_root, path),
         :ok <- ensure_no_symlink_path(workspace_root, full_path),
         true <- File.exists?(full_path) do
      refs =
        cond do
          regular_directory?(full_path) ->
            full_path
            |> walk_files()
            |> Enum.map(fn file -> file_ref!(workspace_root, file) end)

          regular_file?(full_path) ->
            [file_ref!(workspace_root, full_path)]

          true ->
            []
        end

      {:ok, refs}
    else
      false ->
        {:ok, []}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to list docker session files"
         )}
    end
  end

  @impl true
  def delete_file(%Session{} = session, path, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, full_path} <- safe_workspace_path(workspace_root, path),
         :ok <- ensure_no_symlink_path(workspace_root, full_path) do
      case File.rm_rf(full_path) do
        {:ok, _paths} -> :ok
        {:error, reason, _path} -> {:error, Error.from_reason(reason, source: __MODULE__)}
      end
    end
  end

  @impl true
  def checkpoint(%Session{} = session, spec, _opts) do
    with {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, checkpoint_root} <- checkpoint_workspace_root(session, spec),
         :ok <- replace_directory(checkpoint_root),
         :ok <- copy_directory_contents(workspace_root, checkpoint_root) do
      checkpoint_id = Path.basename(checkpoint_root)
      ref = "checkpoint://#{session.id}/#{checkpoint_id}"
      metadata = %{kind: :filesystem, path: checkpoint_root}

      Checkpoint.new(
        id: checkpoint_id,
        session_id: session.id,
        backend: session.backend,
        ref: ref,
        created_at: DateTime.utc_now(),
        metadata:
          Map.put(
            metadata,
            :authority,
            checkpoint_authority(session, checkpoint_id, ref, metadata)
          )
      )
    end
  end

  @impl true
  def restore(%Session{} = session, %Checkpoint{} = checkpoint, _opts) do
    with :ok <- validate_checkpoint(session, checkpoint),
         {:ok, workspace_root} <- session_workspace_root(session),
         {:ok, checkpoint_root} <- checkpoint_path(checkpoint),
         :ok <- verify_checkpoint_authority(session, checkpoint),
         :ok <- ensure_no_symlink_tree(checkpoint_root),
         :ok <- replace_directory(workspace_root),
         :ok <- copy_directory_contents(checkpoint_root, workspace_root) do
      {:ok, session}
    end
  end

  def restore(%Session{}, _checkpoint, _opts) do
    {:error,
     Error.validation("docker session restore requires a filesystem checkpoint",
       source: __MODULE__
     )}
  end

  defp persistent_profile(%Profile{} = profile) do
    workspace = %{profile.workspace | persist?: true}
    %{profile | stateful?: true, workspace: workspace}
  end

  defp session_workspace_root(%Session{} = session) do
    case option(session.metadata, :workspace_root) do
      workspace_root when is_binary(workspace_root) and workspace_root != "" ->
        {:ok, workspace_root}

      _other ->
        session.instance
        |> session_workspace_root()
    end
  end

  defp session_workspace_root(%Instance{} = instance) do
    case option(instance.metadata, :workspace_root) do
      workspace_root when is_binary(workspace_root) and workspace_root != "" ->
        {:ok, workspace_root}

      _other ->
        {:error,
         Error.validation("docker session does not have a managed workspace",
           source: __MODULE__,
           details: %{instance_id: instance.id, backend: instance.backend}
         )}
    end
  end

  defp session_workspace_root(_other) do
    {:error,
     Error.validation("docker session does not have an instance",
       source: __MODULE__
     )}
  end

  defp file_ref!(workspace_root, full_path) do
    {:ok, ref} = file_ref(workspace_root, full_path)
    ref
  end

  defp file_ref(workspace_root, full_path) do
    relative = Path.relative_to(full_path, workspace_root)

    with :ok <- ensure_no_symlink_path(workspace_root, full_path),
         :ok <- ensure_regular_file(full_path),
         {:ok, stat} <- File.lstat(full_path),
         {:ok, content} <- File.read(full_path) do
      FileRef.new(
        path: relative,
        kind: :file,
        bytes: stat.size,
        sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower)
      )
    end
  end

  defp checkpoint_workspace_root(%Session{} = session, spec) do
    spec = if is_list(spec), do: Map.new(spec), else: Map.new(spec || %{})
    session_path_id = host_path_id(session.id)

    checkpoint_id =
      spec
      |> Map.get(:id, Map.get(spec, "id"))
      |> normalize_checkpoint_id()

    {:ok,
     Path.join(
       System.tmp_dir!(),
       "runic_sandbox_checkpoint_#{session_path_id}_#{checkpoint_id}"
     )}
  end

  defp normalize_checkpoint_id(nil), do: "checkpoint_#{System.unique_integer([:positive])}"

  defp normalize_checkpoint_id(id), do: host_path_id(id)

  defp host_path_id(nil), do: "id_#{System.unique_integer([:positive])}"

  defp host_path_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_")
    |> String.trim("._-")
    |> case do
      "" -> "checkpoint_#{System.unique_integer([:positive])}"
      sanitized -> sanitized
    end
  end

  defp validate_checkpoint(%Session{} = session, %Checkpoint{} = checkpoint) do
    cond do
      checkpoint.session_id != session.id ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox session",
           source: __MODULE__,
           details: %{checkpoint_session_id: checkpoint.session_id, session_id: session.id}
         )}

      checkpoint.backend != session.backend ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox backend",
           source: __MODULE__,
           details: %{checkpoint_backend: checkpoint.backend, session_backend: session.backend}
         )}

      checkpoint.metadata[:kind] != :filesystem ->
        {:error,
         Error.validation("docker restore only supports filesystem checkpoints",
           source: __MODULE__,
           details: %{kind: checkpoint.metadata[:kind]}
         )}

      true ->
        :ok
    end
  end

  defp checkpoint_authority(%Session{} = session, checkpoint_id, ref, metadata) do
    snapshot = checkpoint_snapshot(session, checkpoint_id, ref, metadata)
    %{version: 1, signature: checkpoint_signature(snapshot)}
  end

  defp verify_checkpoint_authority(%Session{} = session, %Checkpoint{} = checkpoint) do
    case checkpoint.metadata[:authority] do
      %{version: 1, signature: signature} when is_binary(signature) ->
        metadata = Map.delete(checkpoint.metadata, :authority)
        snapshot = checkpoint_snapshot(session, checkpoint.id, checkpoint.ref, metadata)

        if secure_equal?(signature, checkpoint_signature(snapshot)) do
          :ok
        else
          checkpoint_authority_error(checkpoint, "docker checkpoint authority does not match")
        end

      _other ->
        checkpoint_authority_error(checkpoint, "docker checkpoint authority is missing")
    end
  end

  defp checkpoint_snapshot(%Session{} = session, checkpoint_id, ref, metadata) do
    %{
      id: checkpoint_id,
      session_id: session.id,
      backend: session.backend,
      ref: ref,
      metadata: metadata
    }
  end

  defp checkpoint_signature(snapshot) do
    :hmac
    |> :crypto.mac(:sha256, checkpoint_authority_secret(), :erlang.term_to_binary(snapshot))
    |> Base.encode16(case: :lower)
  end

  defp checkpoint_authority_secret do
    key = {__MODULE__, :checkpoint_authority_secret}

    case :persistent_term.get(key, nil) do
      nil ->
        secret = :crypto.strong_rand_bytes(32)
        :persistent_term.put(key, secret)
        secret

      secret ->
        secret
    end
  end

  defp checkpoint_authority_error(%Checkpoint{} = checkpoint, message) do
    {:error,
     Error.validation(message,
       source: __MODULE__,
       details: %{checkpoint_id: checkpoint.id, session_id: checkpoint.session_id}
     )}
  end

  defp checkpoint_path(%Checkpoint{} = checkpoint) do
    path = checkpoint.metadata[:path]

    cond do
      not is_binary(path) or path == "" ->
        {:error,
         Error.validation("filesystem checkpoint is missing a path",
           source: __MODULE__,
           details: %{checkpoint_id: checkpoint.id}
         )}

      not String.starts_with?(Path.expand(path), Path.expand(System.tmp_dir!()) <> "/") ->
        {:error,
         Error.validation("filesystem checkpoint path is outside the managed checkpoint root",
           source: __MODULE__,
           details: %{checkpoint_id: checkpoint.id}
         )}

      true ->
        {:ok, path}
    end
  end

  defp replace_directory(path) do
    File.rm_rf(path)
    File.mkdir_p(path)
  end

  defp copy_directory_contents(source_root, destination_root) do
    source_root
    |> walk_files()
    |> Enum.reduce_while(:ok, fn source_path, :ok ->
      relative = Path.relative_to(source_path, source_root)
      destination_path = Path.join(destination_root, relative)

      with :ok <- File.mkdir_p(Path.dirname(destination_path)),
           {:ok, _bytes} <- File.copy(source_path, destination_path) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt,
           {:error,
            Error.from_reason(reason,
              source: __MODULE__,
              message: "failed to copy docker session filesystem"
            )}}
      end
    end)
  end

  defp run_container(
         %Instance{} = instance,
         %ExecutionRequest{} = request,
         command,
         workspace_root
       ) do
    container_name = "runic-sandbox-#{System.unique_integer([:positive])}"

    args =
      [
        "run",
        "--rm",
        "--pull",
        "never",
        "--name",
        container_name,
        "--workdir",
        request.cwd,
        "--network",
        docker_network(request.network),
        "--mount",
        "type=bind,src=#{workspace_root},dst=#{instance.workspace.mount}"
      ] ++ runtime_args(instance) ++ resource_args(instance) ++ [image(instance) | command]

    invoke_docker(args, request.timeout_ms || @default_timeout_ms, container_name)
  end

  defp open_container_attach(
         %Session{} = session,
         %Instance{} = instance,
         %ExecutionRequest{} = request,
         command,
         workspace_root,
         cleanup?,
         before_files
       ) do
    container_name = "runic-sandbox-attach-#{System.unique_integer([:positive])}"
    started_mono = System.monotonic_time(:millisecond)

    args =
      [
        "run",
        "--rm",
        "--pull",
        "never",
        "-i",
        "--name",
        container_name,
        "--workdir",
        request.cwd,
        "--network",
        docker_network(request.network),
        "--mount",
        "type=bind,src=#{workspace_root},dst=#{instance.workspace.mount}"
      ] ++ runtime_args(instance) ++ resource_args(instance) ++ [image(instance) | command]

    with {:ok, port} <- open_docker_port(args) do
      if request.stdin != "", do: Port.command(port, request.stdin)

      events =
        Stream.resource(
          fn ->
            timer_ref = attach_timer(request.timeout_ms, port, container_name)

            %{
              session: session,
              request: request,
              port: port,
              timer_ref: timer_ref,
              container_name: container_name,
              workspace_root: workspace_root,
              cleanup?: cleanup?,
              before_files: before_files,
              started?: false,
              finished?: false,
              started_mono: started_mono
            }
          end,
          &next_attach_event/1,
          &cleanup_attach_stream/1
        )

      AttachHandle.new(
        id: AttachEvents.attach_id(),
        session_id: session.id,
        backend: session.backend,
        events: events,
        metadata: %{
          streaming_live?: true,
          terminal_result?: false,
          port: port,
          container_name: container_name,
          workspace_root: workspace_root,
          cleanup?: cleanup?
        }
      )
    end
  end

  defp open_docker_port(args) do
    executable = System.find_executable("docker") || "docker"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    {:ok, port}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp attach_timer(:infinity, _port, _container_name), do: nil

  defp attach_timer(nil, port, container_name),
    do: attach_timer(@default_timeout_ms, port, container_name)

  defp attach_timer(timeout_ms, port, container_name) when is_integer(timeout_ms) do
    Process.send_after(self(), {:runic_sandbox_attach_timeout, port, container_name}, timeout_ms)
  end

  defp next_attach_event(%{started?: false} = state) do
    event =
      AttachEvents.event(state.session, :exec_started, %{
        runtime: state.request.runtime,
        mode: state.request.mode,
        argv: state.request.argv,
        cwd: state.request.cwd,
        network: state.request.network,
        streaming_live?: true,
        container_name: state.container_name
      })

    {[event], %{state | started?: true}}
  end

  defp next_attach_event(%{port: port} = state) do
    receive do
      {^port, {:data, data}} ->
        event =
          AttachEvents.chunk_event(
            state.session,
            :stdout_chunk,
            cap(data, state.request.max_output_bytes)
          )

        {[event], state}

      {^port, {:exit_status, exit_status}} ->
        state = %{state | finished?: true}
        cancel_attach_timer(state.timer_ref)
        event = docker_attach_finished_event(state, exit_status, false)
        cleanup_attach_stream(state)
        {[event], :halt}

      {:runic_sandbox_attach_timeout, ^port, container_name} ->
        System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
        state = %{state | finished?: true}
        event = docker_attach_finished_event(state, nil, true)
        cleanup_attach_stream(state)
        {[event], :halt}
    end
  end

  defp next_attach_event(:halt), do: {:halt, :halt}

  defp docker_attach_finished_event(state, exit_status, timed_out?) do
    duration_ms = System.monotonic_time(:millisecond) - state.started_mono

    {files_changed, artifacts, diagnostics} =
      case snapshot_files(state.workspace_root) do
        {:ok, after_files} ->
          case workspace_delta(
                 state.workspace_root,
                 state.before_files,
                 after_files,
                 state.request.max_output_bytes
               ) do
            {:ok, files_changed, artifacts} -> {files_changed, artifacts, []}
            {:error, error} -> {[], [], [%{message: error.message, details: error.details}]}
          end

        {:error, error} ->
          {[], [], [%{message: error.message, details: error.details}]}
      end

    AttachEvents.event(state.session, :exec_finished, %{
      status: status(exit_status, timed_out?),
      exit_status: exit_status,
      duration_ms: duration_ms,
      files_changed: files_changed,
      artifacts: artifacts,
      diagnostics: diagnostics,
      resource_usage: %{},
      metadata: %{
        sandbox: state.request.sandbox,
        runtime: state.request.runtime,
        mode: state.request.mode,
        network: state.request.network,
        image: image(state.session.instance),
        container_name: state.container_name,
        streaming_live?: true,
        timed_out?: timed_out?,
        security_boundary?: true
      }
    })
  end

  defp cleanup_attach_stream(:halt), do: :ok

  defp cleanup_attach_stream(%{finished?: finished?} = state) do
    cancel_attach_timer(state.timer_ref)

    unless finished? do
      cleanup_attach(state)
    end

    if state.cleanup?, do: File.rm_rf(state.workspace_root)
    :ok
  end

  defp cleanup_attach(%{port: port, container_name: container_name}) do
    if is_port(port), do: Port.close(port)
    System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
    :ok
  rescue
    _exception -> :ok
  end

  defp cleanup_attach(metadata) when is_map(metadata) do
    cleanup_attach(%{
      port: Map.get(metadata, :port),
      container_name: Map.get(metadata, :container_name)
    })
  end

  defp cancel_attach_timer(nil), do: :ok
  defp cancel_attach_timer(ref), do: Process.cancel_timer(ref)

  defp invoke_docker(args, :infinity, _container_name) do
    case docker_cmd(args) do
      {:ok, output, exit_status} -> {:ok, output, exit_status, false}
      {:error, error} -> {:error, error}
    end
  end

  defp invoke_docker(args, timeout_ms, container_name) when is_integer(timeout_ms) do
    task = Task.async(fn -> docker_cmd(args) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output, exit_status}} ->
        {:ok, output, exit_status, false}

      {:ok, {:error, error}} ->
        {:error, error}

      nil ->
        System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
        {:ok, "", nil, true}
    end
  end

  defp docker_cmd(args) do
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {output, exit_status} -> {:ok, output, exit_status}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp runtime_command(%ExecutionRequest{mode: :command, argv: argv}) when argv != [],
    do: {:ok, argv}

  defp runtime_command(%ExecutionRequest{mode: :command}) do
    {:error, Error.validation("docker command request requires argv", source: __MODULE__)}
  end

  defp runtime_command(%ExecutionRequest{mode: :script, runtime: runtime, source: source}) do
    case Map.fetch(@runtime_commands, runtime) do
      {:ok, command} ->
        {:ok, command ++ [source]}

      :error ->
        {:error,
         Error.validation("unsupported docker sandbox runtime",
           source: __MODULE__,
           details: %{runtime: runtime, supported_runtimes: Map.keys(@runtime_commands)}
         )}
    end
  end

  defp prepare_workspace(%Instance{} = instance, %ExecutionRequest{} = request) do
    case option(instance.metadata, :workspace_root) do
      workspace_root when is_binary(workspace_root) ->
        with :ok <- File.mkdir_p(workspace_root),
             :ok <- write_files(workspace_root, request.files) do
          {:ok, workspace_root, false}
        end

      _other ->
        prepare_one_shot_workspace(request)
    end
  end

  defp ensure_workspace_supported(%Instance{workspace: %{mode: mode}} = instance)
       when mode in [:copy_in, :stateful] do
    if is_binary(instance.workspace.mount) and instance.workspace.mount != "" do
      :ok
    else
      {:error,
       Error.validation("docker sandbox workspace mount must be configured",
         source: __MODULE__,
         details: %{workspace: instance.workspace}
       )}
    end
  end

  defp ensure_workspace_supported(%Instance{} = instance) do
    {:error,
     Error.validation("docker sandbox workspace mode is not supported yet",
       source: __MODULE__,
       details: %{
         mode: instance.workspace.mode,
         supported_modes: [:copy_in, :stateful],
         backend: instance.backend
       }
     )}
  end

  defp prepare_one_shot_workspace(%ExecutionRequest{} = request) do
    workspace_root =
      Path.join(System.tmp_dir!(), "runic_sandbox_#{System.unique_integer([:positive])}")

    case File.mkdir_p(workspace_root) do
      :ok ->
        case write_files(workspace_root, request.files) do
          :ok ->
            {:ok, workspace_root, true}

          {:error, error} ->
            File.rm_rf(workspace_root)
            {:error, error}
        end

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to prepare docker sandbox workspace"
         )}
    end
  end

  defp write_files(_workspace_root, files) when files == %{}, do: :ok

  defp write_files(workspace_root, files) when is_map(files) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      with {:ok, path} <- safe_workspace_path(workspace_root, path),
           :ok <- ensure_no_symlink_path(workspace_root, path),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, to_string(content)) do
        {:cont, :ok}
      else
        {:error, %Error{} = error} ->
          {:halt, {:error, error}}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.from_reason(reason,
              source: __MODULE__,
              message: "failed to prepare docker sandbox workspace"
            )}}
      end
    end)
  end

  defp safe_workspace_path(workspace_root, path) when is_binary(path) and path != "" do
    workspace_root = Path.expand(workspace_root)
    expanded = Path.expand(path, workspace_root)

    if expanded == workspace_root or String.starts_with?(expanded, workspace_root <> "/") do
      {:ok, expanded}
    else
      {:error, %{path: path, workspace_root: workspace_root}}
    end
  end

  defp safe_workspace_path(_workspace_root, path), do: {:error, %{path: path}}

  defp snapshot_files(workspace_root) do
    files =
      workspace_root
      |> walk_files()
      |> Enum.reduce(%{}, fn path, acc ->
        relative = Path.relative_to(path, workspace_root)
        :ok = ensure_no_symlink_path(workspace_root, path)
        :ok = ensure_regular_file(path)
        {:ok, stat} = File.lstat(path)
        {:ok, content} = File.read(path)

        Map.put(acc, relative, %{
          path: relative,
          bytes: stat.size,
          sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower)
        })
      end)

    {:ok, files}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp walk_files(root) do
    cond do
      regular_directory?(root) ->
        case File.ls(root) do
          {:ok, names} ->
            Enum.flat_map(names, fn name ->
              path = Path.join(root, name)

              cond do
                regular_directory?(path) -> walk_files(path)
                regular_file?(path) -> [path]
                true -> []
              end
            end)

          {:error, _reason} ->
            []
        end

      regular_file?(root) ->
        [root]

      true ->
        []
    end
  end

  defp workspace_delta(workspace_root, before_files, after_files, preview_limit) do
    paths = (Map.keys(before_files) ++ Map.keys(after_files)) |> Enum.uniq() |> Enum.sort()

    {files_changed, artifacts} =
      Enum.reduce(paths, {[], []}, fn path, {changes, artifacts} ->
        before_file = Map.get(before_files, path)
        after_file = Map.get(after_files, path)

        case change_kind(before_file, after_file) do
          nil ->
            {changes, artifacts}

          kind ->
            change = %{
              path: path,
              kind: kind,
              before_sha256: before_file && before_file.sha256,
              after_sha256: after_file && after_file.sha256,
              bytes: after_file && after_file.bytes
            }

            artifact =
              if after_file do
                artifact_for(workspace_root, path, after_file, preview_limit)
              end

            {[change | changes], maybe_prepend(artifacts, artifact)}
        end
      end)

    {:ok, Enum.reverse(files_changed), Enum.reverse(artifacts)}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp change_kind(nil, %{}), do: :created
  defp change_kind(%{}, nil), do: :deleted
  defp change_kind(%{sha256: sha}, %{sha256: sha}), do: nil
  defp change_kind(%{}, %{}), do: :modified

  defp artifact_for(workspace_root, path, file, preview_limit) do
    full_path = Path.join(workspace_root, path)
    :ok = ensure_no_symlink_path(workspace_root, full_path)
    :ok = ensure_regular_file(full_path)
    {:ok, content} = File.read(full_path)
    preview = cap(content, min(preview_limit, 4_096))

    %{
      ref: "sandbox://#{path}",
      path: path,
      bytes: file.bytes,
      sha256: file.sha256,
      preview: preview,
      truncated?: byte_size(content) > byte_size(preview)
    }
  end

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, value), do: [value | list]

  defp docker_network(:disabled), do: "none"
  defp docker_network(:host), do: "host"
  defp docker_network(:restricted), do: "none"

  defp resource_args(%Instance{metadata: metadata}) do
    backend_options = Map.get(metadata, :backend_options, %{})

    []
    |> maybe_resource_arg("--memory", option(backend_options, :memory))
    |> maybe_resource_arg("--cpus", option(backend_options, :cpus))
    |> maybe_resource_arg("--pids-limit", option(backend_options, :pids_limit))
  end

  defp maybe_resource_arg(args, _flag, nil), do: args
  defp maybe_resource_arg(args, flag, value), do: args ++ [flag, to_string(value)]

  defp status(_exit_status, true), do: :timeout
  defp status(0, false), do: :pass
  defp status(_exit_status, false), do: :fail

  defp diagnostics(output, max_output_bytes, timed_out?) do
    []
    |> maybe_timeout_diagnostic(timed_out?)
    |> maybe_truncation_diagnostic(output, max_output_bytes)
  end

  defp maybe_timeout_diagnostic(diagnostics, false), do: diagnostics

  defp maybe_timeout_diagnostic(diagnostics, true) do
    [%{message: "container sandbox execution timed out", details: %{}} | diagnostics]
  end

  defp maybe_truncation_diagnostic(diagnostics, output, max_output_bytes) do
    if byte_size(output) > max_output_bytes do
      [
        %{message: "sandbox output truncated", details: %{output_bytes: byte_size(output)}}
        | diagnostics
      ]
    else
      diagnostics
    end
  end

  defp split_output(output), do: {output, ""}

  defp cap(output, max_output_bytes) when byte_size(output) <= max_output_bytes, do: output
  defp cap(output, max_output_bytes), do: binary_part(output, 0, max_output_bytes)

  defp ensure_container_available(%Instance{} = instance) do
    cond do
      not container_available?(instance) ->
        {:error,
         Error.validation(
           "#{instance.backend} container runtime is not available for sandbox execution",
           source: __MODULE__,
           details: %{
             backend: instance.backend,
             docker_available?: docker_available?(),
             runsc_available?: runsc_available?(),
             docker_runsc_runtime_available?: docker_runsc_runtime_available?(),
             container_runtime: option(instance.metadata, :container_runtime)
           }
         )}

      not image_available?(image(instance)) ->
        {:error,
         Error.validation(
           "#{instance.backend} sandbox image is not available locally",
           source: __MODULE__,
           details: %{backend: instance.backend, image: image(instance), pull_policy: :never}
         )}

      true ->
        :ok
    end
  end

  defp container_available?(%Profile{backend: :gvisor}),
    do: docker_available?() and docker_runsc_runtime_available?()

  defp container_available?(%Profile{}), do: docker_available?()

  defp container_available?(%Instance{backend: :gvisor}),
    do: docker_available?() and docker_runsc_runtime_available?()

  defp container_available?(%Instance{}), do: docker_available?()
  defp container_available?(_other), do: docker_available?()

  defp ensure_no_symlink_tree(root) do
    root
    |> walk_entries()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %{type: :symlink}} ->
          {:halt,
           {:error,
            Error.validation("sandbox filesystem path may not be a symlink",
              source: __MODULE__,
              details: %{path: path}
            )}}

        {:ok, _stat} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, Error.from_reason(reason, source: __MODULE__)}}
      end
    end)
  end

  defp ensure_no_symlink_path(workspace_root, full_path) do
    workspace_root = Path.expand(workspace_root)
    full_path = Path.expand(full_path)
    relative = Path.relative_to(full_path, workspace_root)

    if relative == "." do
      ensure_not_symlink(workspace_root)
    else
      relative
      |> Path.split()
      |> Enum.reduce_while(workspace_root, fn component, current ->
        next = Path.join(current, component)

        case File.lstat(next) do
          {:ok, %{type: :symlink}} ->
            {:halt,
             {:error,
              Error.validation("sandbox filesystem path may not be a symlink",
                source: __MODULE__,
                details: %{path: Path.relative_to(next, workspace_root)}
              )}}

          {:ok, _stat} ->
            {:cont, next}

          {:error, :enoent} ->
            {:halt, :ok}

          {:error, reason} ->
            {:halt, {:error, Error.from_reason(reason, source: __MODULE__)}}
        end
      end)
      |> case do
        :ok -> :ok
        path when is_binary(path) -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp ensure_not_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:error,
         Error.validation("sandbox filesystem path may not be a symlink",
           source: __MODULE__,
           details: %{path: path}
         )}

      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp ensure_regular_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:ok, stat} ->
        {:error,
         Error.validation("sandbox filesystem path is not a regular file",
           source: __MODULE__,
           details: %{path: path, type: stat.type}
         )}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp regular_file?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))
  defp regular_directory?(path), do: match?({:ok, %{type: :directory}}, File.lstat(path))

  defp walk_entries(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} ->
        children =
          case File.ls(root) do
            {:ok, names} -> Enum.map(names, &Path.join(root, &1))
            {:error, _reason} -> []
          end

        [root | Enum.flat_map(children, &walk_entries/1)]

      {:ok, _stat} ->
        [root]

      {:error, _reason} ->
        []
    end
  end

  defp exec_ready?(profile_or_instance),
    do: container_available?(profile_or_instance) and image_available?(image(profile_or_instance))

  defp docker_available? do
    case System.find_executable("docker") do
      nil ->
        false

      _path ->
        case System.cmd("docker", ["info", "--format", "{{.ServerVersion}}"],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> true
          _other -> false
        end
    end
  rescue
    _exception -> false
  end

  defp runsc_available? do
    !!System.find_executable("runsc") or docker_runsc_runtime_available?()
  rescue
    _exception -> false
  end

  defp docker_runsc_runtime_available?, do: docker_runtime_available?("runsc")

  defp docker_runtime_available?(runtime) do
    case System.find_executable("docker") do
      nil ->
        false

      docker ->
        runtime_available_from_docker_info?(docker, runtime)
    end
  end

  defp runtime_available_from_docker_info?(docker, runtime) do
    case System.cmd(docker, ["info", "--format", "{{json .Runtimes}}"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> runtime_available_from_json?(runtime)

      _other ->
        false
    end
  rescue
    _exception -> false
  end

  defp runtime_available_from_json?(json, runtime) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, runtimes} when is_map(runtimes) -> Map.has_key?(runtimes, runtime)
      _other -> String.contains?(json, runtime)
    end
  end

  defp image_available?(image) do
    case System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  rescue
    _exception -> false
  end

  defp image(%Profile{} = profile), do: option(profile.backend_options, :image) || @default_image
  defp image(%Instance{} = instance), do: option(instance.metadata, :image) || @default_image
  defp image(_other), do: @default_image

  defp runtime_args(%Instance{backend: :gvisor}), do: ["--runtime", "runsc"]
  defp runtime_args(%Instance{}), do: []

  defp container_runtime(%Profile{backend: :gvisor}), do: "runsc"
  defp container_runtime(%Profile{}), do: nil
  defp container_runtime(_other), do: nil

  defp isolation_level(:gvisor), do: :gvisor
  defp isolation_level(_backend), do: :container

  defp docker_missing_requirements(backend, docker_available?, runsc_available?, image_available?) do
    []
    |> maybe_missing(not docker_available?, :docker, "Docker CLI/daemon is unavailable")
    |> maybe_missing(
      backend == :gvisor and not runsc_available?,
      :runsc,
      "Docker runsc runtime is unavailable"
    )
    |> maybe_missing(
      not image_available?,
      :image,
      "Configured sandbox image is not available locally"
    )
    |> Enum.reverse()
  end

  defp maybe_missing(requirements, true, requirement, message),
    do: [%{requirement: requirement, message: message} | requirements]

  defp maybe_missing(requirements, false, _requirement, _message), do: requirements

  defp health_diagnostics(:gvisor, docker_available?, runsc_available?, image_available?, image) do
    []
    |> maybe_health_diagnostic(docker_available?, "docker daemon is unavailable")
    |> maybe_health_diagnostic(runsc_available?, "Docker runsc runtime is unavailable")
    |> maybe_health_diagnostic(image_available?, "Docker image #{image} is unavailable locally")
    |> Enum.reverse()
  end

  defp health_diagnostics(_backend, docker_available?, _runsc_available?, image_available?, image) do
    []
    |> maybe_health_diagnostic(docker_available?, "docker daemon is unavailable")
    |> maybe_health_diagnostic(image_available?, "Docker image #{image} is unavailable locally")
    |> Enum.reverse()
  end

  defp maybe_health_diagnostic(diagnostics, true, _message), do: diagnostics

  defp maybe_health_diagnostic(diagnostics, false, message),
    do: [%{message: message} | diagnostics]

  defp option(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp option(_map, _key), do: nil

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp stateful?(%Profile{} = profile), do: profile.stateful? or profile.workspace.persist?

  defp stateful_instance?(%Instance{} = instance),
    do: not is_nil(option(instance.metadata, :workspace_root))

  defp maybe_put_stateful_workspace(metadata, %Profile{} = profile) do
    if stateful?(profile) do
      Map.put(
        metadata,
        :workspace_root,
        Path.join(
          System.tmp_dir!(),
          "runic_sandbox_stateful_#{profile.name}_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"
        )
      )
    else
      metadata
    end
  end
end
