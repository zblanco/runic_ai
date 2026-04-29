defmodule RunicAI.Coding.Codex.ExecClient do
  @moduledoc """
  Optional local bridge to `codex exec --json`.

  This module treats Codex as a local, subscription-backed model access path for
  tests and experiments. It never reads Codex credential files.
  """

  alias RunicAI.Coding.Codex.EventNormalizer
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.CommandRunner
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
         {:ok, command_result} <-
           CommandRunner.run(
             workspace,
             %{
               argv: argv,
               cwd: Keyword.get(opts, :cwd, "."),
               timeout_ms: Keyword.get(opts, :max_runtime_ms)
             },
             policy: policy
           ),
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

    if Keyword.get(opts, :close_stdin?, true) do
      {:ok, ["sh", "-c", "exec \"$@\" < /dev/null", "codex-stdin-closed" | codex_argv]}
    else
      {:ok, codex_argv}
    end
  end

  defp policy(opts) do
    CommandPolicy.new(
      timeout_ms: Keyword.get(opts, :max_runtime_ms, 120_000),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, 1_048_576),
      allowed_commands: ["codex", "sh"],
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
