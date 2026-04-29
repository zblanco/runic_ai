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
      tool_scope(recipe),
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

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
