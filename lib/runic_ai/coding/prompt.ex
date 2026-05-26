defmodule RunicAI.Coding.Prompt do
  @moduledoc """
  Prompt assembly for the standard coding agent.

  The prompt is intentionally explicit about tool scope and final-answer
  expectations. It also injects project instructions and a compact workspace
  summary so the first turn starts with useful local context.
  """

  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.Recipe
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace

  @agents_path "AGENTS.md"

  @spec system(Workspace.t(), Recipe.t(), keyword()) :: String.t()
  def system(%Workspace{} = workspace, %Recipe{} = recipe, opts \\ []) when is_list(opts) do
    custom = Keyword.get(opts, :system)

    [
      "You are a local coding agent operating through RunicAI.Coding tools.",
      "Workspace root: #{workspace.root}",
      "Project profile: #{workspace.profile.name}",
      "Mode: #{recipe.mode}",
      "",
      mode_instructions(recipe),
      "",
      profile_instructions(workspace),
      "",
      "Tool scope:",
      "- Prefer workspace-relative paths for all file and command cwd arguments.",
      "- When the task asks you to run, execute, or invoke a local command, use the run_command tool instead of saying you are paused or waiting.",
      tool_scope(recipe),
      "",
      sandbox_instructions(recipe, opts),
      "",
      project_instructions(workspace),
      "",
      "Final answer requirements:",
      "- Summarize the concrete change or answer.",
      "- List changed files when patches were applied.",
      "- List verification commands and their pass/fail/timeout status when commands were run.",
      "- Report objective status when an objective gate or scorecard is active.",
      "- Call out unresolved risks, skipped verification, or remaining failures.",
      custom
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  @spec user(String.t(), Workspace.t(), Recipe.t(), keyword()) :: String.t()
  def user(task, %Workspace{} = workspace, %Recipe{} = recipe, opts \\ [])
      when is_binary(task) and is_list(opts) do
    [
      "Task:",
      task,
      "",
      "Workspace summary:",
      workspace_summary(workspace, opts),
      "",
      "Git status:",
      git_status_summary(workspace, opts),
      "",
      "Run mode:",
      to_string(recipe.mode)
    ]
    |> Enum.join("\n")
  end

  @spec project_instructions(Workspace.t()) :: String.t()
  def project_instructions(%Workspace{} = workspace) do
    path = Path.join(workspace.root, @agents_path)

    case File.read(path) do
      {:ok, content} ->
        """
        Project instructions from #{@agents_path}:
        #{String.trim(content)}
        """

      {:error, _reason} ->
        "Project instructions: no #{@agents_path} file found at workspace root."
    end
  end

  @spec workspace_summary(Workspace.t(), keyword()) :: String.t()
  def workspace_summary(%Workspace{} = workspace, opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :workspace_summary_limit, 40)

    case Tools.list_dir(workspace, %{path: ".", limit: limit}) do
      {:ok, %{entries: entries, truncated?: truncated?}} ->
        names =
          entries
          |> Enum.map(fn entry -> "#{entry.name} (#{entry.type || :unknown})" end)
          |> Enum.join(", ")

        suffix = if truncated?, do: " ...", else: ""
        "root entries: #{names}#{suffix}"

      {:error, error} ->
        "workspace summary unavailable: #{error.message}"
    end
  end

  @spec git_status_summary(Workspace.t(), keyword()) :: String.t()
  def git_status_summary(%Workspace{} = workspace, opts \\ []) when is_list(opts) do
    policy =
      opts
      |> Keyword.get(:command_policy)
      |> case do
        nil -> CommandPolicy.new!(allowed_commands: ["git"], max_output_bytes: 8_192)
        policy -> CommandPolicy.from_input!(policy)
      end

    case Tools.git_status(workspace, %{}, policy) do
      {:ok, %{status: :pass, output: output}} when output != "" ->
        String.trim(output)

      {:ok, %{status: status, output: output}} ->
        "git status #{status}: #{String.trim(output)}"

      {:error, error} ->
        "git status unavailable: #{error.message}"
    end
  end

  defp mode_instructions(%Recipe{name: :polyglot_experiment}) do
    """
    Use read, search, git-read, sandbox_status, and execute_code tools for isolated
    experiments. Do not patch host files or run host project commands. Keep
    generated code and scratch files inside the sandbox unless the user asks for
    a reviewed host change.
    """
  end

  defp mode_instructions(%Recipe{mode: :read_only}) do
    """
    Answer repository questions using read, search, and git-read tools only.
    Do not request patch, command, process, or mutating git tools.
    Cite the files or symbols you inspected in the answer.
    """
  end

  defp mode_instructions(%Recipe{mode: :patch, dry_run?: true}) do
    """
    Inspect before proposing edits. Use apply_patch for all file changes.
    This is a planning-only session: patch calls are forced to dry-run and must
    not mutate the workspace.
    """
  end

  defp mode_instructions(%Recipe{mode: :patch}) do
    """
    Inspect before editing. Use apply_patch for all file changes.
    In apply_patch operations, use create only for paths that do not exist and update for paths that already exist.
    If a patch fails, read the diagnostic, repair the patch, and try again when appropriate.
    """
  end

  defp mode_instructions(%Recipe{mode: :verify, dry_run?: true}) do
    """
    Inspect before proposing edits. Patch calls are forced to dry-run.
    Verification tools may be used to understand current state, but do not claim
    a fix was applied unless a non-dry-run patch was actually applied.
    """
  end

  defp mode_instructions(%Recipe{mode: :verify, verification_policy: :targeted_first}) do
    """
    Inspect before editing. Use apply_patch for all file changes.
    In apply_patch operations, use create only for paths that do not exist and update for paths that already exist.
    Run targeted verification first when a focused test or formatter command is enough.
    Run broader Mix compile/test/format commands when the risk or previous output warrants it.
    After failed verification, repair within the remaining turn budget and verify again.
    Stop when verification passes or the repair budget is exhausted.
    Use an OODA loop for nontrivial work: observe the current workspace and
    tool results, orient against the requested objective and evidence, decide
    the next smallest repair or verification action, then act through tools.
    Do not treat generated scaffold tests as sufficient proof for a feature
    objective. When creating a nested project, run verification from that
    project's directory. If delegate or subagent tools are available, use them
    only for clearly separable work and integrate their results through the
    same verification evidence.
    """
  end

  defp mode_instructions(%Recipe{mode: :verify}) do
    """
    Inspect before editing. Use apply_patch for all file changes.
    In apply_patch operations, use create only for paths that do not exist and update for paths that already exist.
    Run the available Mix compile, test, or formatter tools to verify changes.
    Repair failed verification within the remaining turn budget.
    For nontrivial work, continue until concrete evidence supports the user
    objective or until remaining risks must be reported explicitly.
    """
  end

  defp profile_instructions(%Workspace{profile: %{language: :elixir}}) do
    """
    Elixir editing guidance:
    - Prefer explicit function clauses over default arguments when writing full
      file content through JSON tool calls.
    - If default arguments are necessary, verify the written file contains two
      backslashes for `\\\\`, not a single `\\`.
    """
  end

  defp profile_instructions(_workspace), do: nil

  defp tool_scope(%Recipe{} = recipe) do
    recipe.visible_tools
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
  end

  defp sandbox_instructions(%Recipe{visible_tools: visible_tools}, opts) do
    if Enum.any?(visible_tools, &(&1 in ["execute_code", "sandbox_status"])) do
      summary = sandbox_summary(opts)

      """
      Sandbox execution:
      - Use execute_code for arbitrary generated code, polyglot experiments, untrusted snippets, isolated runtime probes, or code that should not mutate the host workspace.
      - Use run_command for project-native host commands only when run_command is visible; otherwise use project_command and verification tools for normal project checks.
      - Prefer deterministic safe computing or built-in project verification when it directly expresses the task; escalate to execute_code when an isolated runtime is the better fit.
      - Active sandbox profile: backend=#{format_value(summary.backend)}; runtimes=#{format_value(summary.runtimes)}; network=#{format_value(summary.network)}; stateful=#{format_value(summary.stateful?)}; workspace=#{format_value(summary.workspace)}; review=#{format_value(summary.review)}.
      - Summarize sandbox diagnostics and artifact refs instead of pasting large stdout or generated files into the final answer.
      """
    end
  end

  defp sandbox_summary(opts) do
    config = sandbox_config(opts)

    %{
      backend: config_value(config, :backend, config_value(config, :default_backend, :just_bash)),
      runtimes: config_value(config, :allowed_runtimes, config_value(config, :runtimes, [:bash])),
      network: config_value(config, :network, :disabled),
      stateful?: config_value(config, :stateful?, false),
      workspace: config_value(config, :workspace, %{mode: :copy_in, persist?: false}),
      review: config_value(config, :review, :unsafe_actions)
    }
  end

  defp sandbox_config(opts) do
    case Keyword.get(opts, :sandbox_opts, []) do
      sandbox_opts when is_list(sandbox_opts) ->
        case Keyword.get(sandbox_opts, :profile) do
          profile when is_list(profile) or is_map(profile) -> profile
          _other -> tool_code_execution_config(opts)
        end

      _other ->
        tool_code_execution_config(opts)
    end
  end

  defp tool_code_execution_config(opts) do
    opts
    |> Keyword.get(:tool_config, %{})
    |> config_value(:code_execution, %{})
  end

  defp config_value(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp config_value(config, key, default) when is_list(config) do
    Keyword.get(config, key, Keyword.get(config, Atom.to_string(key), default))
  end

  defp config_value(_config, _key, default), do: default

  defp format_value(values) when is_list(values) do
    values
    |> Enum.map(&format_value/1)
    |> Enum.join(",")
  end

  defp format_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> "#{key}=#{format_value(nested)}" end)
    |> Enum.sort()
    |> Enum.join(",")
  end

  defp format_value(value), do: to_string(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
