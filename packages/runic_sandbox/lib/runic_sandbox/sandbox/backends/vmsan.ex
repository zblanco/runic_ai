defmodule RunicSandbox.Backends.Vmsan do
  @moduledoc """
  vmsan-backed local Firecracker microVM sandbox backend.

  vmsan owns the low-level Firecracker, jailer, network, agent, and image
  lifecycle. This adapter keeps RunicSandbox's provider-neutral session and
  execution contracts around that CLI surface.
  """

  @behaviour RunicSandbox.Backend

  alias RunicSandbox.Capabilities
  alias RunicSandbox.Checkpoint
  alias RunicSandbox.Error
  alias RunicSandbox.ExecutionRequest
  alias RunicSandbox.ExecutionResult
  alias RunicSandbox.FileRef
  alias RunicSandbox.HostProbe
  alias RunicSandbox.Instance
  alias RunicSandbox.Profile
  alias RunicSandbox.Session
  alias RunicSandbox.VmsanCLI

  @transfer_root_name "runic_sandbox_vmsan_files"

  @impl true
  def provision(%Profile{backend: :vmsan} = profile, opts) do
    health = doctor(opts)

    metadata = %{
      security_boundary?: true,
      backend_module: __MODULE__,
      executable: health.executable,
      available?: health.available?,
      host_available?: health.available?,
      configured?: health.available?,
      exec_ready?: health.available?,
      stateful?: true,
      doctor: redact_doctor(health),
      backend_options: profile.backend_options
    }

    {:ok,
     Instance.from_profile(profile,
       id: Keyword.get(opts, :id),
       state: if(health.available?, do: :ready, else: :unavailable),
       metadata: metadata
     )}
  end

  def provision(%Profile{} = profile, _opts) do
    {:error,
     Error.validation(
       "vmsan backend cannot provision profile backend #{inspect(profile.backend)}",
       source: __MODULE__,
       details: %{backend: profile.backend}
     )}
  end

  @impl true
  def exec(%Instance{} = instance, %ExecutionRequest{} = request, opts) do
    with {:ok, profile} <- one_shot_profile(instance, request),
         {:ok, session} <- open_session(profile, opts) do
      exec_one_shot_session(session, request, opts)
    end
  end

  @impl true
  def upload(%Instance{}, _files, _opts),
    do: {:error, Error.validation("vmsan upload requires an open session", source: __MODULE__)}

  @impl true
  def download(%Instance{}, _paths, _opts),
    do: {:error, Error.validation("vmsan download requires an open session", source: __MODULE__)}

  @impl true
  def snapshot(%Instance{} = instance, _opts) do
    {:ok,
     %{
       instance_id: instance.id,
       backend: :vmsan,
       stateful?: true,
       microvm?: true
     }}
  end

  @impl true
  def reset(%Instance{}, _opts), do: :ok

  @impl true
  def destroy(%Instance{} = instance, opts), do: remove_vm(instance.id, opts)

  @impl true
  def health(opts) do
    doctor = doctor(opts)
    available? = doctor.available?

    {:ok,
     %{
       name: :vmsan,
       available?: available?,
       host_available?: available?,
       configured?: available?,
       exec_ready?: available?,
       executable: doctor.executable,
       version: vmsan_version(opts),
       runtimes: [:bash, :sh, :python, :node, :elixir, :lua],
       isolation_level: :microvm,
       transport_model: :local_microvm,
       state_model: :checkpointable,
       network: %{default: :disabled, provider_managed?: true},
       stateful?: true,
       security_boundary?: true,
       capabilities: Capabilities.to_map(session_capabilities()),
       missing_requirements: doctor.missing_requirements,
       diagnostics: doctor.diagnostics,
       doctor: redact_doctor(doctor)
     }}
  end

  @impl true
  def open_session(%Profile{backend: :vmsan} = profile, opts) do
    with {:ok, transfer_root} <- create_transfer_root() do
      case open_session_with_transfer_root(profile, opts, transfer_root) do
        {:ok, session} ->
          {:ok, session}

        {:error, _error} = result ->
          cleanup_transfer_root(transfer_root)
          result
      end
    end
  end

  @impl true
  def close_session(%Session{} = session, opts) do
    remove_result = remove_vm(session.id, session_opts(session, opts))
    cleanup_transfer_root(session)
    remove_result
  end

  @impl true
  def exec_session(%Session{} = session, %ExecutionRequest{} = request, opts) do
    started = System.monotonic_time(:millisecond)

    with :ok <- ensure_available(opts),
         :ok <- ensure_supported_request(request),
         :ok <- write_request_files(session, request, request.files, opts),
         {:ok, argv} <- request_argv(request),
         {:ok, result} <-
           VmsanCLI.exec_args(session.id, argv, workdir: request.cwd, env: request_env(request))
           |> run_vmsan(session_cli_opts(session, request_opts(request, opts))) do
      duration_ms = System.monotonic_time(:millisecond) - started
      stdout = cap(result.stream_output, request.max_output_bytes)

      ExecutionResult.new(
        status: if(result.exit_status == 0, do: :pass, else: :fail),
        stdout: stdout,
        stderr: "",
        exit_status: result.exit_status,
        duration_ms: duration_ms,
        files_changed: [],
        artifacts: [],
        backend: :vmsan,
        isolation_level: :microvm,
        diagnostics: diagnostics(result.stream_output, request.max_output_bytes),
        resource_usage: %{},
        metadata: %{
          sandbox: request.sandbox,
          runtime: request.runtime,
          mode: request.mode,
          network: request.network,
          vm_id: session.id,
          session_id: session.id,
          security_boundary?: true
        }
      )
    end
  end

  @impl true
  def write_file(%Session{} = session, path, contents, opts) do
    with {:ok, tmp_root} <- tmp_root(session),
         {:ok, local_path} <- safe_tmp_path(tmp_root, local_transfer_path(path)),
         :ok <- File.mkdir_p(Path.dirname(local_path)),
         :ok <- File.write(local_path, contents),
         {:ok, _result} <-
           VmsanCLI.upload_args(session.id, [local_path], dest: Path.dirname(remote_path(path)))
           |> run_vmsan(session_cli_opts(session, opts)),
         {:ok, stat} <- File.stat(local_path) do
      FileRef.new(
        path: path,
        kind: :file,
        bytes: stat.size,
        sha256: Base.encode16(:crypto.hash(:sha256, IO.iodata_to_binary(contents)), case: :lower)
      )
    end
  end

  @impl true
  def read_file(%Session{} = session, path, opts) do
    with {:ok, tmp_root} <- tmp_root(session),
         {:ok, local_path} <- safe_tmp_path(tmp_root, local_transfer_path(path)),
         :ok <- File.mkdir_p(Path.dirname(local_path)),
         {:ok, _result} <-
           VmsanCLI.download_args(session.id, remote_path(path), dest: local_path)
           |> run_vmsan(session_cli_opts(session, opts)),
         :ok <- ensure_regular_file(local_path) do
      File.read(local_path)
    end
  end

  @impl true
  def list_files(%Session{}, _path, _opts),
    do:
      {:error,
       Error.validation("vmsan list_files is not supported by the CLI adapter yet",
         source: __MODULE__
       )}

  @impl true
  def delete_file(%Session{} = session, path, opts) do
    request =
      ExecutionRequest.new!(
        sandbox: session.sandbox,
        runtime: :bash,
        source: "rm -rf -- #{shell_escape(remote_path(path))}"
      )

    case exec_session(session, request, opts) do
      {:ok, %{status: :pass}} ->
        :ok

      {:ok, result} ->
        {:error,
         Error.validation("vmsan delete_file failed",
           source: __MODULE__,
           details: %{result: result}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def checkpoint(%Session{} = session, _spec, opts) do
    with {:ok, result} <-
           VmsanCLI.snapshot_create_args(session.id) |> run_vmsan(session_opts(session, opts)) do
      event = result.event

      checkpoint_id =
        Map.get(event, "snapshotId") || "snapshot_#{System.unique_integer([:positive])}"

      Checkpoint.new(
        id: checkpoint_id,
        session_id: session.id,
        backend: :vmsan,
        ref: "vmsan://#{session.id}/snapshots/#{checkpoint_id}",
        created_at: DateTime.utc_now(),
        metadata: %{
          kind: :microvm_snapshot,
          snapshot_path: Map.get(event, "snapshotPath"),
          mem_path: Map.get(event, "memPath")
        }
      )
    end
  end

  @impl true
  def restore(%Session{} = session, %Checkpoint{} = checkpoint, opts) do
    with :ok <- validate_checkpoint(session, checkpoint),
         {:ok, profile} <-
           Profile.new(
             name: session.sandbox,
             backend: :vmsan,
             runtimes: restore_runtimes(session),
             network: session.policy.network,
             backend_options:
               session_backend_options(session)
               |> Map.put(:snapshot, checkpoint.id)
           ),
         {:ok, restored} <- open_session(profile, opts) do
      close_session(session, opts)
      {:ok, restored}
    end
  end

  def restore(%Session{}, _checkpoint, _opts),
    do:
      {:error, Error.validation("vmsan restore requires a vmsan checkpoint", source: __MODULE__)}

  defp create_vm(%Profile{} = profile, opts) do
    backend_options = profile.backend_options

    create_opts =
      backend_options
      |> Map.take([
        :vcpus,
        :memory,
        :kernel,
        :rootfs,
        :runtime,
        :project,
        :disk,
        :timeout,
        :bandwidth,
        :snapshot
      ])
      |> Map.put(:network_policy, network_policy(profile.policy.network))

    with {:ok, result} <-
           create_opts
           |> VmsanCLI.create_args()
           |> run_vmsan(
             opts
             |> Keyword.put(:sudo?, sudo?(profile))
             |> Keyword.put_new(:executable, profile_executable(profile, opts))
           ) do
      event = result.event

      case Map.get(event, "vmId") do
        vm_id when is_binary(vm_id) and vm_id != "" ->
          {:ok, %{vm_id: vm_id, event: event}}

        _other ->
          {:error,
           Error.validation("vmsan create did not return a vmId",
             source: __MODULE__,
             details: %{event: event}
           )}
      end
    end
  end

  defp exec_one_shot_session(%Session{} = session, %ExecutionRequest{} = request, opts) do
    result = exec_session(session, request, opts)

    case {result, close_session(session, opts)} do
      {{:ok, execution_result}, :ok} ->
        {:ok, execution_result}

      {{:ok, execution_result}, {:error, cleanup_error}} ->
        {:error,
         Error.validation("vmsan one-shot cleanup failed",
           source: __MODULE__,
           details: %{execution_result: execution_result, cleanup_error: cleanup_error}
         )}

      {{:error, execution_error}, _cleanup_result} ->
        {:error, execution_error}
    end
  end

  defp open_session_with_transfer_root(%Profile{} = profile, opts, transfer_root) do
    with :ok <- ensure_available(opts),
         {:ok, vm} <- create_vm(profile, opts) do
      case session_from_vm(profile, opts, transfer_root, vm) do
        {:ok, session} ->
          {:ok, session}

        {:error, _error} = result ->
          remove_vm(
            vm.vm_id,
            opts
            |> Keyword.put(:sudo?, sudo?(profile))
            |> Keyword.put_new(:executable, profile_executable(profile, opts))
          )

          result
      end
    end
  end

  defp session_from_vm(%Profile{} = profile, opts, transfer_root, vm) do
    with {:ok, instance} <-
           provision(%{profile | stateful?: true}, Keyword.put(opts, :id, vm.vm_id)) do
      Session.from_instance(instance,
        id: vm.vm_id,
        capabilities: session_capabilities(),
        policy: profile.policy,
        state_model: :checkpointable,
        transport_model: :local_microvm,
        persistent_identity?: true,
        workspace_ref: "vmsan://#{vm.vm_id}",
        metadata: %{
          vm_id: vm.vm_id,
          event: vm.event,
          executable: profile_executable(profile, opts),
          sudo?: sudo?(profile),
          transfer_root: transfer_root
        }
      )
    end
  end

  defp remove_vm(vm_id, opts) do
    case VmsanCLI.remove_args(vm_id) |> run_vmsan(opts) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp run_vmsan(args, opts) do
    VmsanCLI.run_json(args,
      executable: executable(opts),
      sudo?: Keyword.get(opts, :sudo?, false),
      runner: Keyword.get(opts, :runner, &System.cmd/3),
      timeout_ms: Keyword.get(opts, :timeout_ms, 60_000)
    )
  end

  defp ensure_available(opts) do
    case doctor(opts) do
      %{available?: true} ->
        :ok

      doctor ->
        {:error,
         Error.validation("vmsan sandbox provider is not available for execution",
           source: __MODULE__,
           details: %{
             missing_requirements: doctor.missing_requirements,
             diagnostics: doctor.diagnostics
           }
         )}
    end
  end

  defp doctor(opts),
    do: HostProbe.vmsan_doctor(commands: Keyword.get(opts, :commands, &System.cmd/3))

  defp redact_doctor(doctor), do: Map.drop(doctor, [:raw_output])

  defp vmsan_version(opts) do
    commands = Keyword.get(opts, :commands, &System.cmd/3)

    case System.find_executable(executable(opts)) do
      nil ->
        nil

      path ->
        case commands.(path, ["--version"], stderr_to_stdout: true) do
          {output, _status} -> String.trim(output)
          _other -> nil
        end
    end
  rescue
    _exception -> nil
  end

  defp request_argv(%ExecutionRequest{mode: :command, argv: argv}) when argv != [],
    do: {:ok, argv}

  defp request_argv(%ExecutionRequest{mode: :command}) do
    {:error, Error.validation("vmsan command request requires argv", source: __MODULE__)}
  end

  defp request_argv(%ExecutionRequest{mode: :script, runtime: runtime, source: source}) do
    case runtime do
      runtime when runtime in [:bash, :sh] ->
        {:ok, ["sh", "-lc", source]}

      :python ->
        {:ok, ["python3", "-c", source]}

      :node ->
        {:ok, ["node", "-e", source]}

      :elixir ->
        {:ok, ["elixir", "-e", source]}

      :lua ->
        {:ok, ["lua", "-e", source]}

      _other ->
        {:error,
         Error.validation("unsupported vmsan sandbox runtime",
           source: __MODULE__,
           details: %{runtime: runtime}
         )}
    end
  end

  defp session_capabilities do
    Capabilities.new!(
      exec?: true,
      files?: false,
      inline_files?: false,
      artifacts?: false,
      session_files?: true,
      checkpoints?: true,
      services?: false,
      proxy?: false,
      leases?: false,
      network_policy?: true,
      persistent_identity?: true
    )
  end

  defp request_policy(%ExecutionRequest{} = request) do
    RunicSandbox.Policy.new!(
      network: request.network,
      timeout_ms: request.timeout_ms,
      max_output_bytes: request.max_output_bytes,
      allowed_runtimes: [request.runtime],
      isolation_minimum: :microvm,
      persist_changes?: true
    )
  end

  defp validate_checkpoint(%Session{} = session, %Checkpoint{} = checkpoint) do
    cond do
      checkpoint.session_id != session.id ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox session", source: __MODULE__)}

      checkpoint.backend != :vmsan ->
        {:error,
         Error.validation("checkpoint belongs to a different sandbox backend", source: __MODULE__)}

      checkpoint.metadata[:kind] != :microvm_snapshot ->
        {:error,
         Error.validation("vmsan restore only supports microVM checkpoints", source: __MODULE__)}

      true ->
        :ok
    end
  end

  defp restore_runtimes(%Session{policy: %{allowed_runtimes: [_ | _] = runtimes}}), do: runtimes
  defp restore_runtimes(%Session{}), do: [:bash]

  defp tmp_root(%Session{} = session) do
    case Map.get(session.metadata, :transfer_root) || Map.get(session.metadata, "transfer_root") do
      path when is_binary(path) and path != "" ->
        with :ok <- ensure_transfer_root(path) do
          {:ok, path}
        end

      _other ->
        create_transfer_root()
    end
  end

  defp safe_tmp_path(root, path) do
    root = Path.expand(root)
    path = Path.expand(path, root)

    cond do
      path == root ->
        {:error, Error.validation("vmsan file path must name a file", source: __MODULE__)}

      not String.starts_with?(path, root <> "/") ->
        {:error,
         Error.validation("vmsan file path escapes managed temp root", source: __MODULE__)}

      true ->
        with :ok <- ensure_no_symlink_path(root, path) do
          {:ok, path}
        end
    end
  end

  defp remote_path(path), do: "/" <> (path |> to_string() |> String.trim_leading("/"))
  defp network_policy(:disabled), do: "deny-all"
  defp network_policy(:restricted), do: "deny-all"
  defp network_policy(:host), do: "allow-all"

  defp sudo?(%Profile{} = profile), do: Map.get(profile.backend_options, :sudo?, false)
  defp executable(opts), do: Keyword.get(opts, :executable, "vmsan")

  defp profile_executable(%Profile{} = profile, opts),
    do: Map.get(profile.backend_options, :executable, executable(opts))

  defp one_shot_profile(%Instance{} = instance, %ExecutionRequest{} = request) do
    Profile.new(
      name: instance.name,
      backend: :vmsan,
      runtimes: [request.runtime],
      network: request.network,
      stateful?: true,
      policy: request_policy(request),
      backend_options: Map.get(instance.metadata, :backend_options, %{}),
      metadata: Map.take(instance.metadata, [:executable])
    )
  end

  defp ensure_supported_request(%ExecutionRequest{stdin: stdin}) when stdin not in [nil, ""] do
    {:error,
     Error.validation("vmsan exec does not support stdin yet",
       source: __MODULE__,
       details: %{field: :stdin}
     )}
  end

  defp ensure_supported_request(%ExecutionRequest{}), do: :ok

  defp request_opts(%ExecutionRequest{} = request, opts) do
    Keyword.put(opts, :timeout_ms, request.timeout_ms)
  end

  defp write_request_files(_session, _request, files, _opts) when files in [%{}, nil], do: :ok

  defp write_request_files(%Session{} = session, %ExecutionRequest{} = request, files, opts)
       when is_map(files) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      with {:ok, guest_path} <- request_file_path(request.cwd, path),
           {:ok, _file_ref} <- write_file(session, guest_path, to_string(content), opts) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp request_env(%ExecutionRequest{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :env, Map.get(metadata, "env", %{})) do
      env when is_map(env) or is_list(env) -> env
      _other -> %{}
    end
  end

  defp session_opts(%Session{} = session, opts) do
    opts
    |> Keyword.put_new(:executable, session_executable(session))
    |> Keyword.put_new(:sudo?, session_sudo?(session))
  end

  defp session_cli_opts(%Session{} = session, opts) do
    opts
    |> Keyword.put_new(:executable, session_executable(session))
    |> Keyword.put_new(:sudo?, false)
  end

  defp session_executable(%Session{} = session),
    do: Map.get(session.metadata, :executable, Map.get(session.metadata, "executable", "vmsan"))

  defp session_sudo?(%Session{} = session),
    do: Map.get(session.metadata, :sudo?, Map.get(session.metadata, "sudo?", false))

  defp session_backend_options(%Session{} = session) do
    %{}
    |> Map.put(:sudo?, session_sudo?(session))
    |> Map.put(:executable, session_executable(session))
  end

  defp create_transfer_root do
    root =
      Path.join([
        System.tmp_dir!(),
        @transfer_root_name,
        "#{System.unique_integer([:positive])}-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      ])

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- ensure_transfer_root(root) do
      {:ok, root}
    else
      {:error, reason} when is_atom(reason) ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to create vmsan transfer root"
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp request_file_path(cwd, path) do
    path = to_string(path)
    cwd = Path.expand(cwd || "/workspace")

    cond do
      path == "" ->
        {:error, Error.validation("vmsan inline file path must be non-empty", source: __MODULE__)}

      String.starts_with?(path, "/") ->
        {:error,
         Error.validation("vmsan inline file path must be relative to the request cwd",
           source: __MODULE__,
           details: %{path: path, cwd: cwd}
         )}

      true ->
        guest_path = Path.expand(path, cwd)

        if guest_path != cwd and String.starts_with?(guest_path, cwd <> "/") do
          {:ok, guest_path}
        else
          {:error,
           Error.validation("vmsan inline file path escapes the request cwd",
             source: __MODULE__,
             details: %{path: path, cwd: cwd}
           )}
        end
    end
  end

  defp local_transfer_path(path) do
    path
    |> to_string()
    |> String.trim_leading("/")
  end

  defp ensure_transfer_root(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, access: access}} when access in [:read_write, :write] ->
        :ok

      {:ok, %{type: :directory}} ->
        :ok

      {:ok, stat} ->
        {:error,
         Error.validation("vmsan transfer root is not a directory",
           source: __MODULE__,
           details: %{path: path, type: stat.type}
         )}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp cleanup_transfer_root(%Session{} = session) do
    case Map.get(session.metadata, :transfer_root, Map.get(session.metadata, "transfer_root")) do
      path when is_binary(path) and path != "" ->
        cleanup_transfer_root(path)

      _other ->
        :ok
    end

    :ok
  end

  defp cleanup_transfer_root(path) when is_binary(path) do
    root = Path.join(System.tmp_dir!(), @transfer_root_name) |> Path.expand()
    expanded = Path.expand(path)

    if String.starts_with?(expanded, root <> "/") do
      File.rm_rf(expanded)
    end

    :ok
  end

  defp ensure_no_symlink_path(root, full_path) do
    root = Path.expand(root)
    full_path = Path.expand(full_path)
    relative = Path.relative_to(full_path, root)

    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn component, current ->
      next = Path.join(current, component)

      case File.lstat(next) do
        {:ok, %{type: :symlink}} ->
          {:halt,
           {:error,
            Error.validation("vmsan transfer path may not be a symlink",
              source: __MODULE__,
              details: %{path: Path.relative_to(next, root)}
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

  defp ensure_regular_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:ok, stat} ->
        {:error,
         Error.validation("vmsan transfer path is not a regular file",
           source: __MODULE__,
           details: %{path: path, type: stat.type}
         )}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp cap(output, max) when byte_size(output) <= max, do: output
  defp cap(output, max), do: binary_part(output, 0, max)

  defp diagnostics(output, max) do
    if byte_size(output) > max do
      [%{message: "sandbox output truncated", details: %{output_bytes: byte_size(output)}}]
    else
      []
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
end
