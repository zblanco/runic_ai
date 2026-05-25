defmodule RunicAI.Coding.Codex.ExecClient do
  @moduledoc """
  Optional local bridge to `codex exec --json`.

  This module treats Codex as a local, subscription-backed model access path for
  tests and experiments. It never reads Codex credential files.
  """

  alias RunicAI.Coding.Codex.EventNormalizer
  alias RunicAI.Coding.Command
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.CommandResult
  alias RunicAI.Coding.CommandRunner
  alias RunicAI.Coding.Patch
  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @spec run(Workspace.t() | keyword() | map() | Path.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(workspace_input, prompt, opts \\ [])

  def run(workspace_input, prompt, opts)
      when is_binary(prompt) and is_list(opts) do
    with {:ok, workspace} <- Workspace.from_input(workspace_input),
         {:ok, argv} <- argv(prompt, opts),
         {:ok, policy} <- policy(opts),
         {:ok, command_result} <- run_command(workspace, argv, policy, opts),
         :ok <- ensure_command_pass(command_result),
         {:ok, normalized} <- EventNormalizer.normalize_jsonl(command_result.output) do
      {:ok,
       %{
         command: command_result,
         events: normalized.trace_events,
         raw_events: normalized.raw_events,
         final: normalized.final
       }}
    end
  end

  def run(_workspace, prompt, _opts) do
    {:error,
     Error.validation("codex exec prompt must be a binary",
       source: __MODULE__,
       details: %{prompt: prompt}
     )}
  end

  defp argv(prompt, opts) do
    base = ["codex", "exec", "--json"]

    model_args =
      case Keyword.get(opts, :model) do
        model when is_binary(model) and model != "" -> ["--model", model]
        _other -> []
      end

    sandbox_args =
      case Keyword.get(opts, :sandbox_mode) do
        nil -> []
        sandbox_mode -> ["--sandbox", to_string(sandbox_mode)]
      end

    approval_args =
      case Keyword.get(opts, :approval_mode) do
        nil -> []
        approval_mode -> ["--ask-for-approval", to_string(approval_mode)]
      end

    codex_argv = base ++ model_args ++ sandbox_args ++ approval_args ++ [prompt]
    codex_argv = maybe_wrap_timeout(codex_argv, opts)

    if Keyword.get(opts, :close_stdin?, true) do
      {:ok, ["sh", "-c", "exec \"$@\" < /dev/null", "codex-stdin-closed" | codex_argv]}
    else
      {:ok, codex_argv}
    end
  end

  defp maybe_wrap_timeout(argv, opts) do
    timeout_ms = Keyword.get(opts, :max_runtime_ms)

    if is_integer(timeout_ms) and timeout_ms > 0 and System.find_executable("timeout") do
      ["timeout", "--kill-after=2s", "#{ceil(timeout_ms / 1_000)}s" | argv]
    else
      argv
    end
  end

  defp command_runner_timeout_ms(opts) do
    timeout_ms = Keyword.get(opts, :max_runtime_ms)

    if is_integer(timeout_ms) and timeout_ms > 0 and System.find_executable("timeout") do
      timeout_ms + 4_000
    else
      timeout_ms
    end
  end

  defp run_command(workspace, argv, policy, opts) do
    command_input = %{
      argv: argv,
      cwd: Keyword.get(opts, :cwd, "."),
      timeout_ms: command_runner_timeout_ms(opts)
    }

    case Keyword.get(opts, :event_sink) do
      sink when is_function(sink, 1) ->
        run_streaming_command(workspace, command_input, policy, sink)

      _other ->
        CommandRunner.run(workspace, command_input, policy: policy)
    end
  end

  defp run_streaming_command(workspace, command_input, policy, event_sink) do
    with {:ok, command} <- Command.from_input(command_input) do
      case CommandPolicy.authorize(policy, workspace, command) do
        {:ok, authorization} ->
          {:ok, execute_streaming(workspace, command, authorization, event_sink)}

        {:error, %Error{} = error} ->
          {:ok, CommandResult.blocked(command, error)}
      end
    end
  end

  defp execute_streaming(
         workspace,
         %Command{argv: [executable | args]} = command,
         authorization,
         event_sink
       ) do
    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, System.find_executable(executable) || executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:cd, authorization.cwd},
        {:env, authorization.env}
      ])

    outcome =
      collect_port_output(
        port,
        event_sink,
        authorization.timeout_ms,
        started_mono,
        "",
        ""
      )

    completed_at = DateTime.utc_now()
    duration_ms = System.monotonic_time(:millisecond) - started_mono

    normalize_streaming_outcome(
      workspace,
      command,
      authorization,
      outcome,
      started_at,
      completed_at,
      duration_ms
    )
  end

  defp collect_port_output(port, event_sink, timeout_ms, started_mono, output, line_buffer) do
    receive do
      {^port, {:data, chunk}} ->
        {line_buffer, output} = stream_chunk(chunk, line_buffer, output, event_sink)
        collect_port_output(port, event_sink, timeout_ms, started_mono, output, line_buffer)

      {^port, {:exit_status, exit_status}} ->
        emit_line(line_buffer, event_sink)
        {:ok, output, exit_status}
    after
      port_receive_timeout(timeout_ms, started_mono) ->
        close_port(port)
        emit_line(line_buffer, event_sink)
        {:timeout, output, timeout_ms}
    end
  end

  defp port_receive_timeout(:infinity, _started_mono), do: :infinity
  defp port_receive_timeout(nil, _started_mono), do: :infinity

  defp port_receive_timeout(timeout_ms, started_mono)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    elapsed_ms = System.monotonic_time(:millisecond) - started_mono
    max(timeout_ms - elapsed_ms, 0)
  end

  defp stream_chunk(chunk, line_buffer, output, event_sink) do
    output = output <> chunk
    parts = String.split(line_buffer <> chunk, "\n")
    {complete_lines, [line_buffer]} = Enum.split(parts, -1)
    Enum.each(complete_lines, &emit_line(&1, event_sink))
    {line_buffer, output}
  end

  defp emit_line("", _event_sink), do: :ok

  defp emit_line(line, event_sink) do
    with {:ok, raw_event} <- Jason.decode(line),
         true <- is_map(raw_event) do
      event_sink.(EventNormalizer.to_trace_event(raw_event))
    else
      _other -> :ok
    end
  rescue
    _exception -> :ok
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _exception -> :ok
  end

  defp normalize_streaming_outcome(
         workspace,
         command,
         authorization,
         {:ok, output, exit_status},
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
        full_output_sha256: Patch.sha256(output),
        streamed?: true
      }
    )
  end

  defp normalize_streaming_outcome(
         _workspace,
         command,
         authorization,
         {:timeout, output, timeout_ms},
         started_at,
         completed_at,
         duration_ms
       ) do
    CommandResult.new!(:timeout,
      command: Command.display(command),
      argv: command.argv,
      cwd: authorization.cwd,
      output: output,
      output_preview: String.slice(output, 0, authorization.max_output_bytes),
      output_bytes: byte_size(output),
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
        mutates?: authorization.mutates?,
        streamed?: true
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

  defp policy(opts) do
    CommandPolicy.new(
      timeout_ms: command_runner_timeout_ms(opts) || 120_000,
      max_output_bytes: Keyword.get(opts, :max_output_bytes, 1_048_576),
      allowed_commands: ["codex", "sh", "timeout"],
      env_allowlist: [],
      allow_shell: false,
      metadata: %{bridge: :codex_exec}
    )
  end

  defp ensure_command_pass(%{status: :pass}), do: :ok

  defp ensure_command_pass(%{status: :timeout} = result) do
    {:error,
     Error.timeout("codex exec command timed out",
       source: __MODULE__,
       details: command_error_details(result)
     )}
  end

  defp ensure_command_pass(result) do
    {:error,
     Error.provider("codex exec command failed",
       source: __MODULE__,
       details: command_error_details(result)
     )}
  end

  defp command_error_details(result) do
    %{
      status: Map.get(result, :status),
      exit_status: Map.get(result, :exit_status),
      duration_ms: Map.get(result, :duration_ms),
      output_preview: Map.get(result, :output_preview),
      diagnostics: Map.get(result, :diagnostics, [])
    }
  end
end
