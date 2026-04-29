defmodule RunicAI.Coding.CommandRunner do
  @moduledoc """
  Bounded local command runner for coding tools.
  """

  alias RunicAI.Coding.Command
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.CommandResult
  alias RunicAI.Coding.Patch
  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @spec run(Workspace.t(), Command.t() | keyword() | map(), keyword()) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def run(%Workspace{} = workspace, command_input, opts \\ []) when is_list(opts) do
    policy_input = Keyword.get(opts, :policy)

    with {:ok, command} <- Command.from_input(command_input),
         {:ok, policy} <- CommandPolicy.from_input(policy_input) do
      case CommandPolicy.authorize(policy, workspace, command) do
        {:ok, authorization} ->
          {:ok, execute(workspace, command, authorization)}

        {:error, %Error{} = error} ->
          {:ok, CommandResult.blocked(command, error)}
      end
    end
  end

  defp execute(workspace, command, authorization) do
    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time(:millisecond)
    authorization = isolate_command_env(workspace, command, authorization)

    outcome =
      command
      |> command_fun(authorization)
      |> invoke(authorization.timeout_ms)

    completed_at = DateTime.utc_now()
    duration_ms = System.monotonic_time(:millisecond) - started_mono

    normalize_outcome(
      workspace,
      command,
      authorization,
      outcome,
      started_at,
      completed_at,
      duration_ms
    )
  end

  defp isolate_command_env(%Workspace{} = workspace, %Command{} = command, authorization) do
    if Command.executable(command) |> mix_command?() do
      env =
        authorization.env
        |> put_env_default("MIX_BUILD_ROOT", Path.join(workspace.root, "_build"))

      %{authorization | env: env}
    else
      authorization
    end
  end

  defp mix_command?(nil), do: false
  defp mix_command?(command), do: Path.basename(command) == "mix"

  defp put_env_default(env, key, value) do
    if Enum.any?(env, fn {existing_key, _value} -> existing_key == key end) do
      env
    else
      [{key, value} | env]
    end
  end

  defp command_fun(%Command{backend: :argv, argv: [executable | args]}, authorization) do
    fn ->
      System.cmd(executable, args, system_opts(authorization))
    end
  end

  defp command_fun(%Command{backend: :shell, shell: shell}, authorization) do
    fn ->
      System.cmd("sh", ["-c", shell], system_opts(authorization))
    end
  end

  defp command_fun(%Command{backend: :just_bash, shell: shell, metadata: metadata}, authorization) do
    fn ->
      if Code.ensure_loaded?(JustBash) do
        bash_opts =
          [
            files: Map.get(metadata, :files, Map.get(metadata, "files", %{})),
            env: Map.new(authorization.env),
            cwd: Map.get(metadata, :cwd, Map.get(metadata, "cwd", "/workspace")),
            network: Map.get(metadata, :network, Map.get(metadata, "network", %{enabled: false}))
          ]

        bash = apply(JustBash, :new, [bash_opts])
        {result, _bash} = apply(JustBash, :exec, [bash, shell])

        {
          Map.get(result, :stdout, Map.get(result, "stdout", "")) <>
            Map.get(result, :stderr, Map.get(result, "stderr", "")),
          Map.get(result, :exit_code, Map.get(result, "exit_code", 0))
        }
      else
        {"just_bash is not available; add the optional :just_bash dependency in dev\n", 127}
      end
    end
  end

  defp system_opts(authorization) do
    [
      cd: authorization.cwd,
      env: authorization.env,
      stderr_to_stdout: true
    ]
  end

  defp invoke(fun, :infinity), do: safe_invoke(fun)

  defp invoke(fun, timeout_ms) when is_integer(timeout_ms) do
    task = Task.async(fn -> safe_invoke(fun) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      nil -> {:timeout, timeout_ms}
    end
  end

  defp safe_invoke(fun) do
    {:ok, fun.()}
  rescue
    exception ->
      {:exception, exception}
  end

  defp normalize_outcome(
         workspace,
         command,
         authorization,
         {:ok, {output, exit_status}},
         started_at,
         completed_at,
         duration_ms
       ) do
    {preview, truncated?, artifact_ref} =
      cap_output(workspace, output, authorization.max_output_bytes,
        kind: :command_output,
        command: Command.display(command),
        cwd: authorization.cwd
      )

    status = if exit_status == 0, do: :pass, else: :fail

    CommandResult.new!(status,
      command: Command.display(command),
      argv: command.argv,
      cwd: authorization.cwd,
      exit_status: exit_status,
      output: preview,
      output_preview: preview,
      output_bytes: byte_size(output),
      duration_ms: duration_ms,
      started_at: started_at,
      completed_at: completed_at,
      artifact_ref: artifact_ref,
      truncated?: truncated?,
      metadata: %{
        backend: command.backend,
        classification: authorization.classification,
        network?: authorization.network?,
        mutates?: authorization.mutates?,
        full_output_sha256: Patch.sha256(output)
      }
    )
  end

  defp normalize_outcome(
         _workspace,
         command,
         authorization,
         {:timeout, timeout_ms},
         started_at,
         completed_at,
         duration_ms
       ) do
    CommandResult.new!(:timeout,
      command: Command.display(command),
      argv: command.argv,
      cwd: authorization.cwd,
      output: "",
      output_preview: "",
      output_bytes: 0,
      duration_ms: duration_ms,
      started_at: started_at,
      completed_at: completed_at,
      diagnostics: [
        %{code: :timeout, message: "command timed out", details: %{timeout_ms: timeout_ms}}
      ],
      metadata: %{
        backend: command.backend,
        classification: authorization.classification,
        network?: authorization.network?,
        mutates?: authorization.mutates?
      }
    )
  end

  defp normalize_outcome(
         _workspace,
         command,
         authorization,
         {:exception, exception},
         started_at,
         completed_at,
         duration_ms
       ) do
    CommandResult.new!(:fail,
      command: Command.display(command),
      argv: command.argv,
      cwd: authorization.cwd,
      output: "",
      output_preview: "",
      output_bytes: 0,
      duration_ms: duration_ms,
      started_at: started_at,
      completed_at: completed_at,
      diagnostics: [
        %{
          code: :command_exception,
          message: Exception.message(exception),
          details: %{exception: inspect(exception)}
        }
      ],
      metadata: %{
        backend: command.backend,
        classification: authorization.classification,
        network?: authorization.network?,
        mutates?: authorization.mutates?
      }
    )
  end

  defp cap_output(_workspace, output, max_bytes, _metadata) when byte_size(output) <= max_bytes do
    {output, false, nil}
  end

  defp cap_output(workspace, output, max_bytes, metadata) do
    preview = binary_part(output, 0, max_bytes)
    artifact_ref = put_artifact(workspace, output, metadata)
    {preview, true, artifact_ref || "sha256:#{Patch.sha256(output)}"}
  end

  defp put_artifact(%Workspace{} = workspace, output, metadata) do
    artifact = %{
      content: output,
      byte_size: byte_size(output),
      sha256: Patch.sha256(output),
      metadata: Map.new(metadata)
    }

    case Persistence.put_artifact(workspace.persistence, artifact) do
      {:ok, ref} -> ref
      {:error, _error} -> nil
    end
  end
end
