defmodule RunicAI.Coding.Tools do
  @moduledoc """
  Local coding tool implementations and default tool registry.

  These functions are ordinary Elixir APIs and are also exposed through
  `RunicAI.Tool.Definition` values by `default_registry/2`.
  """

  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.CommandResult
  alias RunicAI.Coding.CommandRunner
  alias RunicAI.Coding.FileArtifact
  alias RunicAI.Coding.Patch
  alias RunicAI.Coding.PatchResult
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.ProcessHandle
  alias RunicAI.Coding.ProcessRegistry
  alias RunicAI.Coding.Profile
  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.VerificationAssertions
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry

  @default_find_ignore ~w(.git .elixir_ls _build deps node_modules)
  @default_list_limit 200
  @default_find_limit 1_000
  @default_search_limit 100

  @spec default_registry(Workspace.t() | keyword() | map() | Path.t(), keyword()) :: Registry.t()
  def default_registry(workspace_input, opts \\ []) when is_list(opts) do
    workspace = Workspace.from_input!(workspace_input)
    command_policy = CommandPolicy.from_input!(Keyword.get(opts, :command_policy))
    process_registry = Keyword.get(opts, :process_registry)
    patch_dry_run? = Keyword.get(opts, :patch_dry_run?, false)

    tools =
      workspace
      |> read_tools()
      |> Kernel.++(patch_tools(workspace, patch_dry_run?))
      |> Kernel.++(command_tools(workspace, command_policy))
      |> Kernel.++(git_tools(workspace, command_policy))
      |> Kernel.++(profile_tools(workspace, command_policy))
      |> Kernel.++(process_tools(workspace, command_policy, process_registry))

    Registry.new!(tools,
      metadata: %{
        kind: :coding,
        workspace_root: workspace.root,
        profile: workspace.profile.name
      }
    )
  end

  @spec list_dir(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def list_dir(%Workspace{} = workspace, args \\ %{}) when is_map(args) do
    path = arg(args, :path, ".")
    include_hidden? = arg(args, :include_hidden, false)
    limit = arg(args, :limit, @default_list_limit)

    with {:ok, limit} <- positive_integer(limit, :limit),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         :ok <- require_directory(resolved.path),
         {:ok, names} <- list_names(resolved.path) do
      entries =
        names
        |> Enum.sort()
        |> Enum.filter(&visible_entry?(workspace, resolved.relative, &1, include_hidden?))
        |> Enum.take(limit)
        |> Enum.map(&entry_metadata(workspace, resolved, &1))

      {:ok,
       %{
         path: resolved.relative,
         entries: entries,
         count: length(entries),
         truncated?: length(names) > limit
       }}
    end
  end

  @spec find_files(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def find_files(%Workspace{} = workspace, args \\ %{}) when is_map(args) do
    path = arg(args, :path, ".")
    include_hidden? = arg(args, :include_hidden, false)
    limit = arg(args, :limit, @default_find_limit)
    query = arg(args, :query, nil)
    ignore = arg(args, :ignore, @default_find_ignore)

    with {:ok, limit} <- positive_integer(limit, :limit),
         {:ok, ignore} <- string_list(ignore, :ignore),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         :ok <- require_directory(resolved.path) do
      files =
        walk_files(
          workspace,
          resolved.path,
          resolved.relative,
          include_hidden?,
          ignore,
          query,
          limit
        )

      {:ok,
       %{
         path: resolved.relative,
         files: files,
         count: length(files),
         truncated?: length(files) >= limit
       }}
    end
  end

  @spec read_file(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def read_file(%Workspace{} = workspace, args) when is_map(args) do
    path = arg(args, :path, nil)
    max_bytes = arg(args, :max_bytes, workspace.path_policy.max_file_bytes)

    with {:ok, max_bytes} <- positive_integer(max_bytes, :max_bytes),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         {:ok, artifact} <- read_artifact(workspace, resolved, max_bytes) do
      {:ok, artifact_to_output(artifact)}
    end
  end

  @spec read_range(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def read_range(%Workspace{} = workspace, args) when is_map(args) do
    path = arg(args, :path, nil)
    start_line = arg(args, :start_line, 1)
    end_line = arg(args, :end_line, start_line)

    with {:ok, start_line} <- positive_integer(start_line, :start_line),
         {:ok, end_line} <- positive_integer(end_line, :end_line),
         :ok <- validate_line_range(start_line, end_line),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         {:ok, content, sha256} <- read_text_content(workspace, resolved) do
      lines = String.split(content, "\n", trim: false)

      selected =
        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {_line, line_no} -> line_no >= start_line and line_no <= end_line end)
        |> Enum.map(fn {line, line_no} -> %{line: line_no, text: line} end)

      text = selected |> Enum.map(& &1.text) |> Enum.join("\n")

      {:ok,
       %{
         path: resolved.relative,
         sha256: sha256,
         start_line: start_line,
         end_line: end_line,
         line_count: length(lines),
         lines: selected,
         text: text
       }}
    end
  end

  @spec read_many(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def read_many(%Workspace{} = workspace, args) when is_map(args) do
    paths = arg(args, :paths, [])
    per_file_max_bytes = arg(args, :per_file_max_bytes, workspace.path_policy.max_file_bytes)
    total_max_bytes = arg(args, :total_max_bytes, workspace.path_policy.max_file_bytes * 2)

    with {:ok, paths} <- string_list(paths, :paths),
         {:ok, per_file_max_bytes} <- positive_integer(per_file_max_bytes, :per_file_max_bytes),
         {:ok, total_max_bytes} <- positive_integer(total_max_bytes, :total_max_bytes) do
      {files, total_bytes, truncated?} =
        Enum.reduce_while(paths, {[], 0, false}, fn path, {files, total_bytes, truncated?} ->
          remaining = max(total_max_bytes - total_bytes, 0)

          if remaining == 0 do
            {:halt, {files, total_bytes, true}}
          else
            max_bytes = min(per_file_max_bytes, remaining)

            case read_file(workspace, %{path: path, max_bytes: max_bytes}) do
              {:ok, output} ->
                bytes = byte_size(output.preview || output.content || "")
                {:cont, {[output | files], total_bytes + bytes, truncated? or output.truncated?}}

              {:error, error} ->
                failure = %{path: path, error: error.message, details: error.details}
                {:cont, {[%{path: path, failure: failure} | files], total_bytes, true}}
            end
          end
        end)

      {:ok,
       %{
         files: Enum.reverse(files),
         count: length(files),
         total_preview_bytes: total_bytes,
         truncated?: truncated?
       }}
    end
  end

  @spec search_text(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def search_text(%Workspace{} = workspace, args) when is_map(args) do
    query = arg(args, :query, nil)

    with {:ok, query} <- non_empty_string(query, :query) do
      search_text_backend(workspace, args, query)
    end
  end

  @spec search_regex(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def search_regex(%Workspace{} = workspace, args) when is_map(args) do
    pattern = arg(args, :pattern, nil)
    flags = arg(args, :flags, "")

    with {:ok, pattern} <- non_empty_string(pattern, :pattern),
         {:ok, regex} <- compile_regex(pattern, flags) do
      search(workspace, args, {:regex, regex})
    end
  end

  @spec apply_patch(Workspace.t(), map()) ::
          {:ok, RunicAI.Coding.PatchResult.t()} | {:error, Error.t()}
  def apply_patch(%Workspace{} = workspace, args) when is_map(args) do
    dry_run? = arg(args, :dry_run, arg(args, :dry_run?, false))

    result =
      Patch.apply_patch(
        workspace,
        %{
          operations: arg(args, :operations, []),
          metadata: normalize_map(arg(args, :metadata, %{}))
        },
        dry_run?: dry_run?
      )

    {:ok, result}
  end

  @spec run_command(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def run_command(%Workspace{} = workspace, args, policy \\ nil) when is_map(args) do
    command_input =
      %{
        backend: arg(args, :backend, :argv),
        argv: arg(args, :argv, nil),
        command: arg(args, :command, nil),
        args: arg(args, :args, []),
        shell: arg(args, :shell, nil),
        cwd: arg(args, :cwd, "."),
        env: arg(args, :env, %{}),
        timeout_ms: arg(args, :timeout_ms, nil),
        metadata: arg(args, :metadata, %{})
      }

    CommandRunner.run(workspace, command_input, policy: policy)
  end

  @spec git_status(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_status(workspace, args \\ %{}, policy \\ nil) do
    run_git(workspace, ["status", "--short", "--branch"], args, policy)
  end

  @spec git_diff(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_diff(workspace, args \\ %{}, policy \\ nil) do
    extra =
      case arg(args, :path, nil) do
        nil -> []
        path -> ["--", path]
      end

    run_git(workspace, ["diff" | extra], args, policy)
  end

  @spec git_log(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_log(workspace, args \\ %{}, policy \\ nil) do
    limit = arg(args, :limit, 20)

    with {:ok, limit} <- positive_integer(limit, :limit) do
      run_git(workspace, ["log", "--oneline", "-n", Integer.to_string(limit)], args, policy)
    end
  end

  @spec git_show(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_show(workspace, args, policy \\ nil) do
    ref = arg(args, :ref, "HEAD")
    run_git(workspace, ["show", "--stat", "--patch", ref], args, policy)
  end

  @spec git_branch(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_branch(workspace, args \\ %{}, policy \\ nil) do
    run_git(workspace, ["branch", "--show-current"], args, policy)
  end

  @spec run_profile_task(
          Workspace.t(),
          Profile.task(),
          map(),
          CommandPolicy.t() | keyword() | map() | nil
        ) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def run_profile_task(%Workspace{} = workspace, task, args \\ %{}, policy \\ nil) do
    extra_args = arg(args, :args, [])
    cwd = arg(args, :cwd, ".")

    with {:ok, extra_args} <- string_list(extra_args, :args),
         {:ok, argv} <- profile_command(workspace, task, cwd) do
      run_command(
        workspace,
        %{
          argv: argv ++ extra_args,
          cwd: cwd,
          timeout_ms: arg(args, :timeout_ms, nil)
        },
        policy
      )
    end
  end

  defp profile_command(%Workspace{} = workspace, task, cwd) do
    case Profile.command(workspace.profile, task) do
      {:ok, argv} ->
        {:ok, argv}

      {:error, workspace_error} ->
        with {:ok, resolved} <- Workspace.resolve_path(workspace, cwd, :read),
             {:ok, cwd_profile} <- Profile.detect(resolved.path),
             {:ok, argv} <- Profile.command(cwd_profile, task) do
          {:ok, argv}
        else
          {:error, _error} -> {:error, workspace_error}
        end
    end
  end

  @spec source_assert(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def source_assert(%Workspace{} = workspace, args) when is_map(args) do
    checks = List.wrap(arg(args, :checks, []))
    context = normalize_map(arg(args, :context, %{}))

    results =
      Enum.map(checks, fn check ->
        VerificationAssertions.evaluate(workspace, check, context)
      end)

    {:ok,
     %{
       status:
         if(Enum.any?(results, &AcceptanceCheck.blocking_failure?/1),
           do: :fail,
           else: :pass
         ),
       results: results,
       passed: Enum.count(results, &(&1.status == :pass)),
       failed: Enum.count(results, &(&1.status == :fail)),
       skipped: Enum.count(results, &(&1.status == :skipped))
     }}
  end

  @spec changed_file_inventory(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def changed_file_inventory(%Workspace{} = workspace, args \\ %{}) when is_map(args) do
    paths = List.wrap(arg(args, :paths, []))
    include_hashes? = arg(args, :include_hashes, true)

    with {:ok, paths} <- inventory_paths(workspace, paths) do
      files =
        Enum.map(paths, fn path ->
          inventory_entry(workspace, path, include_hashes?)
        end)

      {:ok,
       %{
         files: files,
         count: length(files),
         workspace_root: workspace.root
       }}
    end
  end

  @spec project_command(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def project_command(%Workspace{} = workspace, args, policy \\ nil) when is_map(args) do
    cond do
      task = arg(args, :task, nil) ->
        run_profile_task(workspace, normalize_profile_task(task), args, policy)

      argv = arg(args, :argv, nil) ->
        run_command(workspace, Map.put(args, :argv, argv), policy)

      command = arg(args, :command, nil) ->
        run_command(workspace, Map.put(args, :command, command), policy)

      true ->
        {:error,
         Error.validation("project command requires task, argv, or command",
           source: __MODULE__,
           details: %{args: args}
         )}
    end
  end

  @spec runtime_smoke(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def runtime_smoke(%Workspace{} = workspace, args, policy \\ nil) when is_map(args) do
    adapter = arg(args, :adapter, workspace.profile.name)

    case adapter do
      :mix ->
        mix_runtime_smoke(workspace, args, policy)

      "mix" ->
        mix_runtime_smoke(workspace, args, policy)

      _other ->
        project_command(workspace, args, policy)
    end
  end

  defp read_tools(workspace) do
    [
      definition(
        "list_dir",
        "List one workspace directory with metadata.",
        [
          path: [type: :string, default: "."],
          include_hidden: [type: :boolean, default: false],
          limit: [type: :pos_integer, default: @default_list_limit]
        ],
        fn args -> list_dir(workspace, args) end,
        %{category: :coding, mutates?: false}
      ),
      definition(
        "find_files",
        "Find files under a workspace path.",
        [
          path: [type: :string, default: "."],
          query: [type: :string],
          include_hidden: [type: :boolean, default: false],
          ignore: [type: {:list, :string}, default: @default_find_ignore],
          limit: [type: :pos_integer, default: @default_find_limit]
        ],
        fn args -> find_files(workspace, args) end,
        %{category: :coding, mutates?: false}
      ),
      definition(
        "read_file",
        "Read one workspace text file with hash and truncation metadata.",
        [
          path: [type: :string, required: true],
          max_bytes: [type: :pos_integer]
        ],
        fn args -> read_file(workspace, args) end,
        %{category: :coding, mutates?: false}
      ),
      definition(
        "read_range",
        "Read a line range from one workspace text file.",
        [
          path: [type: :string, required: true],
          start_line: [type: :pos_integer, required: true],
          end_line: [type: :pos_integer, required: true]
        ],
        fn args -> read_range(workspace, args) end,
        %{category: :coding, mutates?: false}
      ),
      definition(
        "read_many",
        "Read several workspace text files with total output caps.",
        [
          paths: [type: {:list, :string}, required: true],
          per_file_max_bytes: [type: :pos_integer],
          total_max_bytes: [type: :pos_integer]
        ],
        fn args -> read_many(workspace, args) end,
        %{category: :coding, mutates?: false}
      ),
      definition(
        "search_text",
        "Search workspace text files for a literal string.",
        [
          query: [type: :string, required: true],
          path: [type: :string, default: "."],
          include_hidden: [type: :boolean, default: false],
          context_lines: [type: :non_neg_integer, default: 0],
          limit: [type: :pos_integer, default: @default_search_limit]
        ],
        fn args -> search_text(workspace, args) end,
        %{category: :coding, mutates?: false}
      ),
      definition(
        "search_regex",
        "Search workspace text files with a regular expression.",
        [
          pattern: [type: :string, required: true],
          flags: [type: :string, default: ""],
          path: [type: :string, default: "."],
          include_hidden: [type: :boolean, default: false],
          context_lines: [type: :non_neg_integer, default: 0],
          limit: [type: :pos_integer, default: @default_search_limit]
        ],
        fn args -> search_regex(workspace, args) end,
        %{category: :coding, mutates?: false}
      ),
      definition(
        "source_assert",
        "Evaluate deterministic source assertions against workspace files.",
        [
          checks: [type: :any, required: true],
          context: [type: :any]
        ],
        fn args -> source_assert(workspace, args) end,
        %{category: :coding_verify, mutates?: false}
      ),
      definition(
        "changed_file_inventory",
        "Report file metadata and hashes for selected or discovered workspace files.",
        [
          paths: [type: {:list, :string}, default: []],
          include_hashes: [type: :boolean, default: true]
        ],
        fn args -> changed_file_inventory(workspace, args) end,
        %{category: :coding_verify, mutates?: false}
      )
    ]
  end

  defp patch_tools(workspace, patch_dry_run?) do
    [
      definition(
        "apply_patch",
        "Apply structured create, update, delete, and move operations.",
        [
          operations: [type: :any, required: true],
          dry_run: [type: :boolean, default: false],
          metadata: [type: :any]
        ],
        fn args ->
          args =
            if patch_dry_run? do
              Map.put(args, :dry_run, true)
            else
              args
            end

          apply_patch(workspace, args)
        end,
        %{category: :coding, mutates?: true, requires_review?: true},
        timeout: 30_000,
        stop_on_error: true
      )
    ]
  end

  defp command_tools(workspace, command_policy) do
    [
      definition(
        "run_command",
        "Run a bounded workspace command through direct argv by default.",
        [
          argv: [type: :any],
          command: [type: :string],
          args: [type: {:list, :string}, default: []],
          cwd: [type: :string, default: "."],
          env: [type: :any],
          timeout_ms: [type: :pos_integer],
          backend: [type: :string, default: "argv"],
          shell: [type: :string],
          metadata: [type: :any]
        ],
        fn args -> run_command(workspace, args, command_policy) end,
        %{category: :coding, mutates?: :command_dependent, requires_review?: true},
        timeout: :infinity,
        stop_on_error: false
      )
    ]
  end

  defp git_tools(workspace, command_policy) do
    [
      definition(
        "git_status",
        "Read git status for the workspace.",
        [],
        fn args -> git_status(workspace, args, command_policy) end,
        %{category: :coding_git, mutates?: false}
      ),
      definition(
        "git_diff",
        "Read git diff for the workspace or one path.",
        [path: [type: :string]],
        fn args -> git_diff(workspace, args, command_policy) end,
        %{category: :coding_git, mutates?: false}
      ),
      definition(
        "git_log",
        "Read recent git log entries.",
        [limit: [type: :pos_integer, default: 20]],
        fn args -> git_log(workspace, args, command_policy) end,
        %{category: :coding_git, mutates?: false}
      ),
      definition(
        "git_show",
        "Read one git revision with stat and patch.",
        [ref: [type: :string, default: "HEAD"]],
        fn args -> git_show(workspace, args, command_policy) end,
        %{category: :coding_git, mutates?: false}
      ),
      definition(
        "git_branch",
        "Read current git branch name.",
        [],
        fn args -> git_branch(workspace, args, command_policy) end,
        %{category: :coding_git, mutates?: false}
      )
    ]
  end

  defp profile_tools(workspace, command_policy) do
    [
      definition(
        "compile_project",
        "Run the detected project compile command.",
        [args: [type: {:list, :string}, default: []], cwd: [type: :string, default: "."]],
        fn args -> run_profile_task(workspace, :compile_project, args, command_policy) end,
        %{category: :coding_profile, mutates?: :profile_dependent}
      ),
      definition(
        "run_tests",
        "Run the detected project test command.",
        [args: [type: {:list, :string}, default: []], cwd: [type: :string, default: "."]],
        fn args -> run_profile_task(workspace, :run_tests, args, command_policy) end,
        %{category: :coding_profile, mutates?: :profile_dependent}
      ),
      definition(
        "run_formatter",
        "Run the detected project formatter command.",
        [args: [type: {:list, :string}, default: []], cwd: [type: :string, default: "."]],
        fn args -> run_profile_task(workspace, :run_formatter, args, command_policy) end,
        %{category: :coding_profile, mutates?: true, requires_review?: true}
      ),
      definition(
        "run_linter",
        "Run the detected project lint/check command.",
        [args: [type: {:list, :string}, default: []], cwd: [type: :string, default: "."]],
        fn args -> run_profile_task(workspace, :run_linter, args, command_policy) end,
        %{category: :coding_profile, mutates?: false}
      ),
      definition(
        "project_command",
        "Run a generic project command adapter by profile task or argv.",
        [
          task: [type: :string],
          argv: [type: :any],
          command: [type: :string],
          args: [type: {:list, :string}, default: []],
          cwd: [type: :string, default: "."],
          timeout_ms: [type: :pos_integer]
        ],
        fn args -> project_command(workspace, args, command_policy) end,
        %{category: :coding_profile, mutates?: :profile_dependent}
      ),
      definition(
        "runtime_smoke",
        "Run a guarded project runtime smoke through the active project adapter.",
        [
          adapter: [type: :string],
          code: [type: :string],
          argv: [type: :any],
          command: [type: :string],
          args: [type: {:list, :string}, default: []],
          cwd: [type: :string, default: "."],
          timeout_ms: [type: :pos_integer]
        ],
        fn args -> runtime_smoke(workspace, args, command_policy) end,
        %{category: :coding_profile, mutates?: :profile_dependent}
      )
    ]
  end

  defp process_tools(_workspace, _command_policy, nil), do: []

  defp process_tools(workspace, command_policy, process_registry) do
    [
      definition(
        "start_process",
        "Start a bounded background process.",
        [
          argv: [type: :any],
          command: [type: :string],
          args: [type: {:list, :string}, default: []],
          cwd: [type: :string, default: "."],
          env: [type: :any],
          timeout_ms: [type: :pos_integer]
        ],
        fn args ->
          command_input =
            Map.take(args, [
              :argv,
              "argv",
              :command,
              "command",
              :args,
              "args",
              :cwd,
              "cwd",
              :env,
              "env",
              :timeout_ms,
              "timeout_ms"
            ])

          ProcessRegistry.start_process(process_registry, workspace, command_input,
            policy: command_policy
          )
        end,
        %{category: :coding_process, mutates?: :command_dependent, requires_review?: true}
      ),
      definition(
        "process_poll",
        "Poll a managed background process.",
        [id: [type: :string, required: true]],
        fn args -> ProcessRegistry.poll(process_registry, arg(args, :id, nil)) end,
        %{category: :coding_process, mutates?: false}
      ),
      definition(
        "process_log",
        "Read recent output from a managed background process.",
        [id: [type: :string, required: true], max_bytes: [type: :pos_integer]],
        fn args ->
          ProcessRegistry.log(process_registry, arg(args, :id, nil),
            max_bytes: arg(args, :max_bytes, 16_384)
          )
        end,
        %{category: :coding_process, mutates?: false}
      ),
      definition(
        "process_write",
        "Write stdin to a managed background process.",
        [id: [type: :string, required: true], input: [type: :string, required: true]],
        fn args ->
          ProcessRegistry.write(process_registry, arg(args, :id, nil), arg(args, :input, ""))
        end,
        %{category: :coding_process, mutates?: true, requires_review?: true}
      ),
      definition(
        "process_kill",
        "Kill a managed background process.",
        [id: [type: :string, required: true]],
        fn args -> ProcessRegistry.kill(process_registry, arg(args, :id, nil)) end,
        %{category: :coding_process, mutates?: true}
      )
    ]
  end

  defp definition(name, description, parameter_schema, executor, metadata, opts \\ []) do
    Definition.new!(
      name: name,
      description: description,
      parameter_schema: parameter_schema,
      executor: model_visible_executor(executor),
      execution_policy: [
        mode: :serial,
        timeout: Keyword.get(opts, :timeout, 30_000),
        stop_on_error: Keyword.get(opts, :stop_on_error, false),
        metadata: Map.merge(%{coding_tool?: true}, metadata)
      ],
      metadata: metadata
    )
  end

  defp model_visible_executor(executor) when is_function(executor, 1) do
    fn args ->
      case executor.(args) do
        {:ok, output} -> {:ok, model_output(output)}
        other -> other
      end
    end
  end

  defp model_output(%PatchResult{} = result), do: result |> Map.from_struct() |> model_output()
  defp model_output(%CommandResult{} = result), do: result |> Map.from_struct() |> model_output()
  defp model_output(%ProcessHandle{} = handle), do: handle |> Map.from_struct() |> model_output()

  defp model_output(%FileArtifact{} = artifact),
    do: artifact |> Map.from_struct() |> model_output()

  defp model_output(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp model_output(%Range{} = range) do
    %{first: range.first, last: range.last, step: range.step}
  end

  defp model_output(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {key, model_output(value)} end)
  end

  defp model_output(value) when is_list(value), do: Enum.map(value, &model_output/1)
  defp model_output(value), do: value

  defp run_git(workspace, git_args, args, policy) do
    cwd = arg(args, :cwd, ".")
    timeout_ms = arg(args, :timeout_ms, nil)

    git_policy =
      policy
      |> CommandPolicy.from_input!()
      |> Map.put(:allowed_commands, ["git"])

    run_command(
      workspace,
      %{argv: ["git" | git_args], cwd: cwd, timeout_ms: timeout_ms},
      git_policy
    )
  end

  defp search(workspace, args, matcher) do
    path = arg(args, :path, ".")
    include_hidden? = arg(args, :include_hidden, false)
    context_lines = arg(args, :context_lines, 0)
    limit = arg(args, :limit, @default_search_limit)

    with {:ok, context_lines} <- non_neg_integer(context_lines, :context_lines),
         {:ok, limit} <- positive_integer(limit, :limit),
         {:ok, found} <-
           find_files(workspace, %{
             path: path,
             include_hidden: include_hidden?,
             limit: @default_find_limit
           }) do
      matches =
        found.files
        |> Enum.reduce_while([], fn file, acc ->
          case search_file(workspace, file.path, matcher, context_lines, limit - length(acc)) do
            {:ok, file_matches} ->
              next = acc ++ file_matches

              if length(next) >= limit do
                {:halt, Enum.take(next, limit)}
              else
                {:cont, next}
              end

            {:skip, _reason} ->
              {:cont, acc}
          end
        end)

      {:ok,
       %{
         path: path,
         matches: matches,
         count: length(matches),
         truncated?: length(matches) >= limit,
         backend: :elixir
       }}
    end
  end

  defp search_text_backend(workspace, args, query) do
    context_lines = arg(args, :context_lines, 0)
    use_rg? = arg(args, :use_rg, true)

    cond do
      use_rg? and context_lines == 0 and System.find_executable("rg") ->
        case search_text_rg(workspace, args, query) do
          {:ok, output} -> {:ok, output}
          {:fallback, _reason} -> search(workspace, args, {:text, query})
          {:error, error} -> {:error, error}
        end

      true ->
        search(workspace, args, {:text, query})
    end
  end

  defp search_text_rg(workspace, args, query) do
    path = arg(args, :path, ".")
    include_hidden? = arg(args, :include_hidden, false)
    limit = arg(args, :limit, @default_search_limit)

    with {:ok, limit} <- positive_integer(limit, :limit),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         :ok <- require_directory_or_file(resolved.path) do
      rg_args =
        [
          "--line-number",
          "--column",
          "--fixed-strings",
          "--color",
          "never",
          "--no-heading"
        ] ++ maybe_hidden_arg(include_hidden?) ++ ["--", query, resolved.path]

      case System.cmd("rg", rg_args, stderr_to_stdout: true) do
        {output, status} when status in [0, 1] ->
          matches =
            output
            |> String.split("\n", trim: true)
            |> Enum.reduce_while([], fn line, acc ->
              case parse_rg_line(workspace, line, query) do
                {:ok, match} ->
                  next = [match | acc]

                  if length(next) >= limit do
                    {:halt, next}
                  else
                    {:cont, next}
                  end

                :skip ->
                  {:cont, acc}
              end
            end)
            |> Enum.reverse()

          {:ok,
           %{
             path: resolved.relative,
             matches: matches,
             count: length(matches),
             truncated?: length(matches) >= limit,
             backend: :rg
           }}

        {_output, _status} ->
          {:fallback, :rg_failed}
      end
    end
  end

  defp parse_rg_line(workspace, line, query) do
    case String.split(line, ":", parts: 4) do
      [path, line_no, column, text] ->
        relative = Path.relative_to(Path.expand(path), workspace.root)

        with {:ok, _resolved} <- Workspace.resolve_path(workspace, relative, :read),
             {line_no, ""} <- Integer.parse(line_no),
             {column, ""} <- Integer.parse(column) do
          {:ok,
           %{
             path: relative,
             line: line_no,
             column: column,
             match: query,
             text: text,
             before: [],
             after: []
           }}
        else
          _other -> :skip
        end

      _other ->
        :skip
    end
  end

  defp search_file(_workspace, _path, _matcher, _context_lines, remaining) when remaining <= 0 do
    {:ok, []}
  end

  defp search_file(workspace, path, matcher, context_lines, remaining) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         {:ok, content, sha256} <- read_text_content(workspace, resolved) do
      lines = String.split(content, "\n", trim: false)

      matches =
        lines
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_no} ->
          line_matches(line, matcher)
          |> Enum.map(fn %{column: column, match: match} ->
            %{
              path: resolved.relative,
              line: line_no,
              column: column,
              match: match,
              text: line,
              before: context(lines, line_no, -context_lines),
              after: context(lines, line_no, context_lines),
              sha256: sha256
            }
          end)
        end)
        |> Enum.take(remaining)

      {:ok, matches}
    else
      {:error, error} -> {:skip, error}
    end
  end

  defp line_matches(line, {:text, query}) do
    line_matches_text(line, query, 0, [])
  end

  defp line_matches(line, {:regex, regex}) do
    case Regex.run(regex, line, return: :index) do
      nil ->
        []

      [{start, length} | _rest] ->
        [%{column: start + 1, match: binary_part(line, start, length)}]
    end
  end

  defp line_matches_text(line, query, offset, acc) do
    case :binary.match(line, query, scope: {offset, byte_size(line) - offset}) do
      :nomatch ->
        Enum.reverse(acc)

      {index, length} ->
        next = %{column: index + 1, match: binary_part(line, index, length)}
        line_matches_text(line, query, index + length, [next | acc])
    end
  end

  defp context(_lines, _line_no, 0), do: []

  defp context(lines, line_no, negative_count) when negative_count < 0 do
    count = abs(negative_count)

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {_line, current} -> current >= line_no - count and current < line_no end)
    |> Enum.map(fn {line, current} -> %{line: current, text: line} end)
  end

  defp context(lines, line_no, count) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {_line, current} -> current > line_no and current <= line_no + count end)
    |> Enum.map(fn {line, current} -> %{line: current, text: line} end)
  end

  defp walk_files(workspace, absolute, relative, include_hidden?, ignore, query, limit) do
    do_walk_files(workspace, absolute, relative, include_hidden?, ignore, query, limit, [])
    |> Enum.reverse()
  end

  defp do_walk_files(
         _workspace,
         _absolute,
         _relative,
         _include_hidden?,
         _ignore,
         _query,
         limit,
         acc
       )
       when length(acc) >= limit do
    acc
  end

  defp do_walk_files(workspace, absolute, relative, include_hidden?, ignore, query, limit, acc) do
    case File.ls(absolute) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while(acc, fn name, acc ->
          child_relative = join_relative(relative, name)
          child_absolute = Path.join(absolute, name)

          cond do
            length(acc) >= limit ->
              {:halt, acc}

            ignored?(child_relative, name, ignore) ->
              {:cont, acc}

            not visible_path?(workspace, child_relative, include_hidden?) ->
              {:cont, acc}

            symlink?(child_absolute) ->
              {:cont, acc}

            File.dir?(child_absolute) ->
              next =
                do_walk_files(
                  workspace,
                  child_absolute,
                  child_relative,
                  include_hidden?,
                  ignore,
                  query,
                  limit,
                  acc
                )

              {:cont, next}

            File.regular?(child_absolute) and query_match?(child_relative, query) ->
              {:cont, [%{path: child_relative} | acc]}

            true ->
              {:cont, acc}
          end
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp read_artifact(workspace, resolved, max_bytes) do
    with {:ok, stat} <- stat_file(resolved.path),
         :ok <- enforce_file_size(workspace, resolved.path, stat.size),
         {:ok, content} <- File.read(resolved.path),
         sha256 = Patch.sha256(content),
         binary? = binary_content?(content),
         {preview, truncated?, artifact_ref} <-
           preview(workspace, content, max_bytes,
             kind: :file_read,
             path: resolved.relative,
             sha256: sha256
           ) do
      {:ok,
       FileArtifact.new!(
         path: resolved.relative,
         content: if(binary?, do: nil, else: preview),
         preview: if(binary?, do: "[binary file omitted]", else: preview),
         sha256: sha256,
         byte_size: stat.size,
         artifact_ref: artifact_ref,
         binary?: binary?,
         truncated?: truncated?,
         metadata: %{source: :workspace}
       )}
    end
  end

  defp read_text_content(workspace, resolved) do
    with {:ok, stat} <- stat_file(resolved.path),
         :ok <- enforce_file_size(workspace, resolved.path, stat.size),
         {:ok, content} <- File.read(resolved.path),
         false <- binary_content?(content) do
      {:ok, content, Patch.sha256(content)}
    else
      true ->
        {:error,
         Error.validation("file is binary",
           source: __MODULE__,
           details: %{path: resolved.relative}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp artifact_to_output(%FileArtifact{} = artifact) do
    %{
      path: artifact.path,
      content: artifact.content,
      preview: artifact.preview,
      sha256: artifact.sha256,
      byte_size: artifact.byte_size,
      binary?: artifact.binary?,
      truncated?: artifact.truncated?,
      artifact_ref: artifact.artifact_ref,
      metadata: artifact.metadata
    }
  end

  defp preview(_workspace, content, max_bytes, _metadata) when byte_size(content) <= max_bytes do
    {content, false, nil}
  end

  defp preview(workspace, content, max_bytes, metadata) do
    artifact_ref = put_artifact(workspace, content, metadata)
    {binary_part(content, 0, max_bytes), true, artifact_ref || "sha256:#{Patch.sha256(content)}"}
  end

  defp put_artifact(%Workspace{} = workspace, content, metadata) do
    artifact = %{
      content: content,
      byte_size: byte_size(content),
      sha256: Patch.sha256(content),
      metadata: Map.new(metadata)
    }

    case Persistence.put_artifact(workspace.persistence, artifact) do
      {:ok, ref} -> ref
      {:error, _error} -> nil
    end
  end

  defp binary_content?(content) do
    match?({_, _}, :binary.match(content, <<0>>)) or not String.valid?(content)
  end

  defp stat_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, stat}

      {:ok, stat} ->
        {:error,
         Error.validation("path must be a regular file",
           source: __MODULE__,
           details: %{path: path, type: stat.type}
         )}

      {:error, reason} ->
        {:error,
         Error.new(:file_stat_failed, "could not stat file",
           source: __MODULE__,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp enforce_file_size(workspace, path, size) do
    if size <= workspace.path_policy.max_file_bytes do
      :ok
    else
      {:error,
       Error.new(:file_too_large, "file exceeds workspace max_file_bytes",
         source: __MODULE__,
         details: %{path: path, size: size, max_file_bytes: workspace.path_policy.max_file_bytes}
       )}
    end
  end

  defp entry_metadata(workspace, resolved, name) do
    child_relative = join_relative(resolved.relative, name)
    child_absolute = Path.join(resolved.path, name)

    stat =
      case File.lstat(child_absolute) do
        {:ok, stat} -> stat
        {:error, _reason} -> nil
      end

    %{
      path: child_relative,
      name: name,
      type: stat && stat.type,
      size: stat && stat.size,
      hidden?: PathPolicy.hidden?(child_relative),
      symlink?: stat && stat.type == :symlink,
      writable?: writable_path?(workspace, child_relative)
    }
  end

  defp writable_path?(workspace, path) do
    match?({:ok, _resolved}, Workspace.resolve_path(workspace, path, :write))
  end

  defp list_names(path) do
    case File.ls(path) do
      {:ok, names} ->
        {:ok, names}

      {:error, reason} ->
        {:error,
         Error.new(:directory_list_failed, "could not list directory",
           source: __MODULE__,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp require_directory(path) do
    if File.dir?(path) do
      :ok
    else
      {:error,
       Error.validation("path must be a directory",
         source: __MODULE__,
         details: %{path: path}
       )}
    end
  end

  defp require_directory_or_file(path) do
    if File.dir?(path) or File.regular?(path) do
      :ok
    else
      {:error,
       Error.validation("path must be a directory or regular file",
         source: __MODULE__,
         details: %{path: path}
       )}
    end
  end

  defp visible_entry?(workspace, parent_relative, name, include_hidden?) do
    visible_path?(workspace, join_relative(parent_relative, name), include_hidden?)
  end

  defp visible_path?(workspace, relative, include_hidden?) do
    hidden? = PathPolicy.hidden?(relative)
    credential? = PathPolicy.credential_path?(relative)

    cond do
      credential? and not workspace.path_policy.allow_credential_paths ->
        false

      hidden? and not include_hidden? ->
        false

      hidden? and workspace.path_policy.hidden_policy == :deny ->
        false

      true ->
        true
    end
  end

  defp ignored?(relative, name, ignore) do
    name in ignore or Enum.any?(ignore, &String.starts_with?(relative, &1 <> "/"))
  end

  defp query_match?(_relative, nil), do: true
  defp query_match?(relative, query) when is_binary(query), do: String.contains?(relative, query)

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _other -> false
    end
  end

  defp maybe_hidden_arg(true), do: ["--hidden"]
  defp maybe_hidden_arg(false), do: []

  defp compile_regex(pattern, flags) do
    Regex.compile(pattern, flags)
    |> case do
      {:ok, regex} ->
        {:ok, regex}

      {:error, reason} ->
        {:error,
         Error.validation("invalid regular expression",
           source: __MODULE__,
           details: %{pattern: pattern, reason: reason}
         )}
    end
  end

  defp validate_line_range(start_line, end_line) when end_line >= start_line, do: :ok

  defp validate_line_range(start_line, end_line) do
    {:error,
     Error.validation("end_line must be greater than or equal to start_line",
       source: __MODULE__,
       details: %{start_line: start_line, end_line: end_line}
     )}
  end

  defp join_relative(".", name), do: name
  defp join_relative(relative, name), do: Path.join(relative, name)

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, field) do
    {:error,
     Error.validation("#{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp non_neg_integer(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_neg_integer(value, field) do
    {:error,
     Error.validation("#{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp string_list(values, _field) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      invalid_string_list(values)
    end
  end

  defp string_list(value, _field) when is_binary(value), do: {:ok, [value]}

  defp string_list(values, _field), do: invalid_string_list(values)

  defp invalid_string_list(values) do
    {:error,
     Error.validation("expected a list of strings",
       source: __MODULE__,
       details: %{values: values}
     )}
  end

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("#{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp inventory_paths(workspace, []) do
    with {:ok, found} <- find_files(workspace, %{path: ".", limit: 100}) do
      {:ok, Enum.map(found.files, & &1.path)}
    end
  end

  defp inventory_paths(_workspace, paths), do: string_list(paths, :paths)

  defp inventory_entry(workspace, path, include_hashes?) do
    case Workspace.resolve_path(workspace, path, :read) do
      {:ok, resolved} ->
        stat = File.stat(resolved.path)

        entry =
          %{
            path: resolved.relative,
            exists?: File.exists?(resolved.path),
            regular?: File.regular?(resolved.path),
            language: language_for_path(resolved.relative),
            line_count: line_count(resolved.path),
            git_status: git_status_for_path(workspace, resolved.relative)
          }
          |> maybe_put_size(stat)

        if include_hashes? and File.regular?(resolved.path) do
          case Patch.file_sha256(resolved.path) do
            {:ok, sha256} -> Map.put(entry, :sha256, sha256)
            {:error, error} -> Map.put(entry, :hash_error, error.message)
          end
        else
          entry
        end

      {:error, error} ->
        %{path: path, exists?: false, error: error.message, details: error.details}
    end
  end

  defp maybe_put_size(entry, {:ok, %File.Stat{size: size}}), do: Map.put(entry, :bytes, size)
  defp maybe_put_size(entry, {:error, _reason}), do: entry

  defp language_for_path(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".erl" -> :erlang
      ".js" -> :javascript
      ".ts" -> :typescript
      ".tsx" -> :typescript
      ".py" -> :python
      ".rs" -> :rust
      ".go" -> :go
      ".md" -> :markdown
      _other -> :unknown
    end
  end

  defp line_count(path) do
    if File.regular?(path) do
      case File.read(path) do
        {:ok, content} -> content |> String.split("\n", trim: false) |> length()
        {:error, _reason} -> nil
      end
    end
  end

  defp git_status_for_path(workspace, relative) do
    cond do
      not File.dir?(Path.join(workspace.root, ".git")) ->
        nil

      is_nil(System.find_executable("git")) ->
        nil

      true ->
        case System.cmd("git", ["-C", workspace.root, "status", "--short", "--", relative],
               stderr_to_stdout: true
             ) do
          {output, 0} -> String.trim(output)
          {_output, _status} -> nil
        end
    end
  end

  defp normalize_profile_task(task) when is_atom(task), do: task
  defp normalize_profile_task("compile_project"), do: :compile_project
  defp normalize_profile_task("run_tests"), do: :run_tests
  defp normalize_profile_task("run_formatter"), do: :run_formatter
  defp normalize_profile_task("run_linter"), do: :run_linter
  defp normalize_profile_task(task), do: task

  defp mix_runtime_smoke(workspace, args, policy) do
    case arg(args, :code, nil) do
      code when is_binary(code) and code != "" ->
        run_command(
          workspace,
          %{
            argv: ["mix", "run", "-e", code],
            cwd: arg(args, :cwd, "."),
            timeout_ms: arg(args, :timeout_ms, nil),
            metadata: %{runtime_smoke?: true, adapter: :mix}
          },
          policy
        )

      _other ->
        project_command(workspace, args, policy)
    end
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp arg(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
