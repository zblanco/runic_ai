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
  @default_search_line_max_bytes 1_000
  @default_diagram_limit 20
  @default_diagram_preview_max_bytes 2_000
  @default_diagram_file_limit 1_000
  @diagram_file_extensions ~w(.md .livemd .mmd .mermaid)
  @default_diagram_ignore @default_find_ignore ++ ~w(doc/dist docs/dist priv/static/doc/dist)
  @diagram_context_lines 16
  @mermaid_fence_regex ~r/```[ \t]*(?:mermaid|mmd|mmdflux)[^\n]*\n(.*?)\n```/is
  @diagram_query_stopwords ~w(
    can could diagram diagrams document file from get graph into lets mermaid mmdflux notebook now
    project render rendered same that the this tool using with you livebooks describes describe
  )
  @mmdflux_formats ~w(text ascii)
  @mmdflux_colors ~w(auto always off)
  @mmdflux_timeout_ms 10_000
  @mmdflux_max_output_bytes 80_000

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

  @spec extract_diagrams(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def extract_diagrams(%Workspace{} = workspace, args) when is_map(args) do
    path = arg(args, :path, nil)
    query = arg(args, :query, nil)
    limit = arg(args, :limit, @default_diagram_limit)
    include_hidden? = arg(args, :include_hidden, false)
    ignore = arg(args, :ignore, @default_diagram_ignore)
    include_source? = arg(args, :include_source, false) == true
    max_source_bytes = arg(args, :max_source_bytes, @default_diagram_preview_max_bytes)

    with {:ok, limit} <- positive_integer(limit, :limit),
         {:ok, ignore} <- string_list(ignore, :ignore),
         {:ok, max_source_bytes} <- positive_integer(max_source_bytes, :max_source_bytes),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read) do
      cond do
        File.regular?(resolved.path) ->
          extract_diagrams_from_file(
            workspace,
            resolved,
            query,
            limit,
            include_source?,
            max_source_bytes
          )

        File.dir?(resolved.path) ->
          extract_diagrams_from_directory(
            workspace,
            resolved,
            query,
            limit,
            include_source?,
            max_source_bytes,
            include_hidden?,
            ignore
          )

        true ->
          {:error,
           Error.validation("path must be a directory or regular file",
             source: __MODULE__,
             details: %{path: resolved.relative}
           )}
      end
    end
  end

  @spec render_mermaid(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def render_mermaid(%Workspace{} = workspace, args) when is_map(args) do
    diagram_index = arg(args, :diagram_index, 1)
    format = arg(args, :format, "text")
    color = arg(args, :color, "auto")
    query = arg(args, :query, nil)

    with {:ok, diagram_index} <- positive_integer(diagram_index, :diagram_index),
         {:ok, format} <- mmdflux_format(format),
         {:ok, color} <- mmdflux_color(color),
         {:ok, source, source_metadata} <- mermaid_source(workspace, args, diagram_index, query) do
      render_mermaid_source(source, format, color, source_metadata)
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
        "extract_diagrams",
        "List Mermaid diagrams from a workspace file or bounded source directory. Finds raw .mmd files, Markdown Mermaid fences, and static or dynamic Kino.Mermaid Livebook calls. Use this before rendering when the requested diagram is described loosely.",
        [
          path: [type: :string, required: true],
          query: [type: :string],
          limit: [type: :pos_integer, default: @default_diagram_limit],
          include_hidden: [type: :boolean, default: false],
          ignore: [type: {:list, :string}, default: @default_diagram_ignore],
          include_source: [type: :boolean, default: false],
          max_source_bytes: [type: :pos_integer, default: @default_diagram_preview_max_bytes]
        ],
        fn args -> extract_diagrams(workspace, args) end,
        %{category: :coding_visualization, mutates?: false}
      ),
      definition(
        "render_mermaid",
        "Render Mermaid source, a Mermaid fenced code block, a bounded directory candidate, or a static Kino.Mermaid.new triple-quoted Livebook diagram as terminal text using mmdflux. Prefer this directly for Mermaid/MMDFLUX requests; pass path plus optional query text near the desired diagram. Use format text unless ASCII-only output is required.",
        [
          source: [type: :string],
          path: [type: :string],
          query: [type: :string],
          diagram_index: [type: :pos_integer, default: 1],
          format: [type: :string, default: "text"],
          color: [type: :string, default: "auto"]
        ],
        fn args -> render_mermaid(workspace, args) end,
        %{category: :coding_visualization, mutates?: false}
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

  defp extract_diagrams_from_file(
         workspace,
         resolved,
         query,
         limit,
         include_source?,
         max_source_bytes
       ) do
    with {:ok, content, sha256} <- read_text_content(workspace, resolved) do
      diagrams =
        resolved.relative
        |> extract_mermaid_diagrams(content)
        |> with_file_metadata(resolved.relative, sha256)

      normalized_query = normalize_query(query)
      selected = selected_diagram(diagrams, 1, normalized_query)

      {:ok,
       %{
         path: resolved.relative,
         sha256: sha256,
         count: length(diagrams),
         truncated?: length(diagrams) > limit,
         query: normalized_query,
         selected_diagram_index: selected && selected.index,
         diagrams:
           diagrams
           |> Enum.take(limit)
           |> Enum.map(
             &diagram_candidate_output(&1, include_source?, max_source_bytes, normalized_query)
           )
       }}
    end
  end

  defp extract_diagrams_from_directory(
         workspace,
         resolved,
         query,
         limit,
         include_source?,
         max_source_bytes,
         include_hidden?,
         ignore
       ) do
    normalized_query = normalize_query(query)

    files =
      workspace
      |> walk_files(
        resolved.path,
        resolved.relative,
        include_hidden?,
        ignore,
        nil,
        @default_diagram_file_limit
      )
      |> Enum.map(& &1.path)
      |> Enum.filter(&diagram_source_file?/1)

    {diagrams, scanned, errors, truncated?} =
      files
      |> Enum.reduce_while({[], 0, [], false}, fn path, {diagrams, scanned, errors, truncated?} ->
        if length(diagrams) > limit do
          {:halt, {diagrams, scanned, errors, true}}
        else
          case diagrams_from_path(workspace, path) do
            {:ok, file_diagrams} ->
              next = diagrams ++ file_diagrams
              {:cont, {next, scanned + 1, errors, truncated? or length(next) > limit}}

            {:error, error} ->
              {:cont, {diagrams, scanned + 1, [diagram_scan_error(path, error) | errors], true}}
          end
        end
      end)

    diagrams = assign_global_diagram_indexes(diagrams)
    selected = selected_diagram(diagrams, 1, normalized_query)
    diagram_files = diagrams |> Enum.map(& &1.path) |> Enum.uniq()

    {:ok,
     %{
       path: resolved.relative,
       directory?: true,
       files_scanned: scanned,
       diagram_files: diagram_files,
       diagram_file_count: length(diagram_files),
       count: length(diagrams),
       truncated?: truncated? or length(files) >= @default_diagram_file_limit,
       query: normalized_query,
       selected_diagram_index: selected && selected.index,
       scan_errors: Enum.reverse(errors),
       diagrams:
         diagrams
         |> Enum.take(limit)
         |> Enum.map(
           &diagram_candidate_output(&1, include_source?, max_source_bytes, normalized_query)
         )
     }}
  end

  defp diagrams_from_path(workspace, path) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         {:ok, content, sha256} <- read_text_content(workspace, resolved) do
      diagrams =
        resolved.relative
        |> extract_mermaid_diagrams(content)
        |> with_file_metadata(resolved.relative, sha256)

      {:ok, diagrams}
    end
  end

  defp with_file_metadata(diagrams, path, sha256) do
    Enum.map(diagrams, fn diagram ->
      diagram
      |> Map.put(:path, path)
      |> Map.put(:sha256, sha256)
      |> Map.put(:file_diagram_index, diagram.index)
    end)
  end

  defp assign_global_diagram_indexes(diagrams) do
    diagrams
    |> Enum.with_index(1)
    |> Enum.map(fn {diagram, index} -> Map.put(diagram, :index, index) end)
  end

  defp diagram_scan_error(path, %Error{} = error),
    do: %{path: path, error: error.message, details: error.details}

  defp diagram_source_file?(path), do: Path.extname(path) in @diagram_file_extensions

  defp mermaid_source(workspace, args, diagram_index, query) do
    case {arg(args, :source, nil), arg(args, :path, nil)} do
      {source, _path} when is_binary(source) and source != "" ->
        {:ok, String.trim(source), %{source: :inline, diagram_count: 1, diagram_index: 1}}

      {_source, path} when is_binary(path) and path != "" ->
        mermaid_source_from_path(workspace, path, diagram_index, query)

      _other ->
        {:error,
         Error.validation("render_mermaid requires source or path",
           source: __MODULE__,
           details: %{args: args}
         )}
    end
  end

  defp mermaid_source_from_path(workspace, path, diagram_index, query) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read) do
      cond do
        File.regular?(resolved.path) ->
          mermaid_source_from_file(workspace, resolved, diagram_index, query)

        File.dir?(resolved.path) ->
          mermaid_source_from_directory(workspace, resolved, diagram_index, query)

        true ->
          {:error,
           Error.validation("path must be a directory or regular file",
             source: __MODULE__,
             details: %{path: resolved.relative}
           )}
      end
    end
  end

  defp mermaid_source_from_file(workspace, resolved, diagram_index, query) do
    with {:ok, content, sha256} <- read_text_content(workspace, resolved),
         {:ok, diagram, diagram_count} <-
           select_mermaid_diagram(resolved.relative, content, diagram_index, query) do
      {:ok, diagram.source,
       source_metadata(
         :file,
         resolved.relative,
         sha256,
         diagram,
         diagram_count,
         diagram_index,
         query
       )}
    end
  end

  defp mermaid_source_from_directory(workspace, resolved, diagram_index, query) do
    with {:ok, output} <-
           extract_diagrams(workspace, %{
             path: resolved.relative,
             query: query,
             limit: max(diagram_index, @default_diagram_limit),
             include_source: true,
             max_source_bytes: workspace.path_policy.max_file_bytes
           }) do
      diagrams = output.diagrams
      normalized_query = output.query
      selected_index = output.selected_diagram_index || diagram_index

      case Enum.find(diagrams, &(&1.index == selected_index)) ||
             Enum.at(diagrams, diagram_index - 1) do
        %{renderable?: true, source: source} = diagram when is_binary(source) and source != "" ->
          {:ok, source,
           source_metadata(
             :directory,
             diagram.path,
             diagram.sha256,
             diagram,
             output.count,
             diagram_index,
             normalized_query
           )
           |> Map.merge(%{
             directory: resolved.relative,
             diagram_file_count: output.diagram_file_count,
             files_scanned: output.files_scanned
           })}

        %{renderable?: false} = diagram ->
          {:error,
           Error.validation("selected Mermaid diagram is dynamic and cannot be rendered directly",
             source: __MODULE__,
             details: %{
               path: diagram.path,
               diagram_index: diagram.index,
               file_diagram_index: diagram.file_diagram_index,
               container: diagram.container,
               line_start: diagram.line_start,
               line_end: diagram.line_end,
               heading: diagram.heading
             }
           )}

        _other ->
          {:error,
           Error.validation("Mermaid diagram was not found",
             source: __MODULE__,
             details: %{
               path: resolved.relative,
               diagram_index: diagram_index,
               diagram_count: output.count
             }
           )}
      end
    end
  end

  defp source_metadata(source_kind, path, sha256, diagram, diagram_count, diagram_index, query) do
    %{
      source: source_kind,
      path: path,
      sha256: sha256,
      diagram_count: diagram_count,
      diagram_index: diagram.index,
      file_diagram_index: Map.get(diagram, :file_diagram_index),
      requested_diagram_index: diagram_index,
      query: query,
      container: diagram.container,
      line_start: diagram.line_start,
      line_end: diagram.line_end,
      heading: diagram.heading
    }
  end

  defp select_mermaid_diagram(path, content, diagram_index, query) do
    diagrams = extract_mermaid_diagrams(path, content)
    normalized_query = normalize_query(query)
    selected = selected_diagram(diagrams, diagram_index, normalized_query)

    case selected do
      %{source: source, renderable?: true} = diagram when is_binary(source) and source != "" ->
        {:ok, diagram, length(diagrams)}

      %{renderable?: false} = diagram ->
        {:error,
         Error.validation("selected Mermaid diagram is dynamic and cannot be rendered directly",
           source: __MODULE__,
           details: %{
             path: path,
             diagram_index: diagram.index,
             container: diagram.container,
             line_start: diagram.line_start,
             line_end: diagram.line_end,
             heading: diagram.heading,
             expression: diagram.expression
           }
         )}

      _other ->
        {:error,
         Error.validation("Mermaid diagram was not found",
           source: __MODULE__,
           details: %{path: path, diagram_index: diagram_index, diagram_count: length(diagrams)}
         )}
    end
  end

  defp extract_mermaid_diagrams(path, content) do
    diagrams =
      if mermaid_file?(path) do
        [
          %{
            source: String.trim(content),
            context: content,
            container: :mermaid_file,
            renderable?: true,
            line_start: 1,
            line_end: content_line_count(content),
            heading: nil,
            expression: nil
          }
        ]
      else
        extract_mermaid_fences(content) ++ extract_kino_mermaid_blocks(content)
      end

    diagrams
    |> Enum.reject(fn diagram ->
      diagram.renderable? and (not is_binary(diagram.source) or diagram.source == "")
    end)
    |> Enum.sort_by(&{&1.line_start || 0, &1.container})
    |> Enum.with_index(1)
    |> Enum.map(fn {diagram, index} -> Map.put(diagram, :index, index) end)
  end

  defp extract_mermaid_fences(content) do
    @mermaid_fence_regex
    |> Regex.scan(content, return: :index)
    |> Enum.map(fn [{start, length}, {source_start, source_length}] ->
      source = content |> binary_part(source_start, source_length) |> String.trim()
      line_start = line_number_at(content, start)

      %{
        source: source,
        context: diagram_context(content, line_start, source),
        container: :markdown_fence,
        renderable?: true,
        line_start: line_start,
        line_end: line_number_at(content, start + length),
        heading: heading_before_line(content, line_start),
        expression: nil
      }
    end)
    |> Enum.reject(&(&1.source == ""))
  end

  defp extract_kino_mermaid_blocks(content) do
    content
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> scan_kino_mermaid_lines([], content)
  end

  defp scan_kino_mermaid_lines([], acc, _content), do: Enum.reverse(acc)

  defp scan_kino_mermaid_lines([{line, line_no} | rest], acc, content) do
    if String.contains?(line, "Kino.Mermaid.new(") do
      case consume_kino_mermaid_literal(line, line_no, rest) do
        {:ok, source, line_end, remaining} ->
          diagram = %{
            source: source,
            context: diagram_context(content, line_no, source),
            container: :kino_mermaid_literal,
            renderable?: true,
            line_start: line_no,
            line_end: line_end,
            heading: heading_before_line(content, line_no),
            expression: nil
          }

          scan_kino_mermaid_lines(remaining, [diagram | acc], content)

        :not_literal ->
          expression = String.trim(line)

          diagram = %{
            source: nil,
            context: diagram_context(content, line_no, expression),
            container: :kino_mermaid_dynamic,
            renderable?: false,
            line_start: line_no,
            line_end: line_no,
            heading: heading_before_line(content, line_no),
            expression: expression
          }

          scan_kino_mermaid_lines(rest, [diagram | acc], content)
      end
    else
      scan_kino_mermaid_lines(rest, acc, content)
    end
  end

  defp consume_kino_mermaid_literal(line, line_no, rest) do
    with {:ok, _before, after_open} <- split_once(line, "\"\"\"") do
      case split_once(after_open, "\"\"\"") do
        {:ok, source, _after_close} ->
          {:ok, String.trim(source), line_no, rest}

        :error ->
          case collect_triple_quoted_literal(rest, [after_open]) do
            {:ok, source, line_end, remaining} ->
              {:ok, String.trim(source), line_end, remaining}

            :unterminated ->
              :not_literal
          end
      end
    else
      :error -> :not_literal
    end
  end

  defp collect_triple_quoted_literal([], _acc), do: :unterminated

  defp collect_triple_quoted_literal([{line, line_no} | rest], acc) do
    case split_once(line, "\"\"\"") do
      {:ok, before_close, _after_close} ->
        source =
          [before_close | acc]
          |> Enum.reverse()
          |> Enum.join("\n")

        {:ok, source, line_no, rest}

      :error ->
        collect_triple_quoted_literal(rest, [line | acc])
    end
  end

  defp split_once(binary, pattern) do
    case :binary.match(binary, pattern) do
      {start, length} ->
        before = binary_part(binary, 0, start)
        after_match = binary_part(binary, start + length, byte_size(binary) - start - length)
        {:ok, before, after_match}

      :nomatch ->
        :error
    end
  end

  defp normalize_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> case do
      "" -> nil
      query -> String.downcase(query)
    end
  end

  defp normalize_query(_query), do: nil

  defp selected_diagram(diagrams, diagram_index, nil), do: Enum.at(diagrams, diagram_index - 1)

  defp selected_diagram(diagrams, diagram_index, query) do
    select_diagram_by_query(diagrams, query) || Enum.at(diagrams, diagram_index - 1)
  end

  defp select_diagram_by_query(diagrams, query) do
    diagrams
    |> Enum.map(fn diagram -> {diagram, diagram_query_score(diagram, query)} end)
    |> Enum.filter(fn {_diagram, score} -> score > 0 end)
    |> Enum.max_by(
      fn {diagram, score} ->
        {score, if(diagram.renderable?, do: 1, else: 0), -diagram.index}
      end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      {diagram, _score} -> diagram
    end
  end

  defp diagram_query_score(diagram, query) do
    text = diagram_search_text(diagram)
    exact_score = if String.contains?(text, query), do: 100, else: 0
    tokens = query_tokens(query)
    token_score = Enum.count(tokens, &String.contains?(text, &1))

    exact_score + token_score
  end

  defp mermaid_file?(path), do: Path.extname(path) in [".mmd", ".mermaid"]

  defp diagram_search_text(diagram) do
    [diagram.heading, diagram.context, diagram.source, diagram.expression]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp query_tokens(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/, trim: true)
    |> Enum.reject(&(byte_size(&1) < 3 or &1 in @diagram_query_stopwords))
    |> Enum.map(&singularize_token/1)
    |> Enum.uniq()
  end

  defp singularize_token(token) do
    if String.ends_with?(token, "s") and byte_size(token) > 3 do
      String.slice(token, 0, byte_size(token) - 1)
    else
      token
    end
  end

  defp diagram_candidate_output(diagram, include_source?, max_source_bytes, query) do
    source = diagram.source || diagram.expression || ""

    output = %{
      index: diagram.index,
      file_diagram_index: Map.get(diagram, :file_diagram_index),
      path: Map.get(diagram, :path),
      sha256: Map.get(diagram, :sha256),
      container: diagram.container,
      renderable?: diagram.renderable?,
      line_start: diagram.line_start,
      line_end: diagram.line_end,
      heading: diagram.heading,
      query_score: query && diagram_query_score(diagram, query),
      source_preview: truncate_output(source, max_source_bytes),
      source_truncated?: byte_size(source) > max_source_bytes,
      context_preview: truncate_output(diagram.context || "", max_source_bytes)
    }

    if include_source? and diagram.renderable? do
      Map.put(output, :source, diagram.source)
    else
      output
    end
  end

  defp diagram_context(content, line_start, source) do
    before =
      content
      |> String.split("\n", trim: false)
      |> Enum.take(max(line_start - 1, 0))
      |> Enum.take(-@diagram_context_lines)
      |> Enum.join("\n")

    [before, source]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp heading_before_line(content, line_start) do
    content
    |> String.split("\n", trim: false)
    |> Enum.take(max(line_start - 1, 0))
    |> Enum.reverse()
    |> Enum.find(&Regex.match?(~r/^#+\s+\S/, &1))
    |> case do
      nil -> nil
      heading -> Regex.replace(~r/^#+\s+/, heading, "")
    end
  end

  defp line_number_at(content, byte_offset) do
    byte_offset = min(byte_offset, byte_size(content))

    content
    |> binary_part(0, byte_offset)
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end

  defp content_line_count(content), do: content |> String.split("\n", trim: false) |> length()

  defp render_mermaid_source(source, format, color, source_metadata) do
    case System.find_executable("mmdflux") do
      nil ->
        {:ok,
         Map.merge(source_metadata, %{
           status: :blocked,
           command: "mmdflux --format #{format} --color #{color}",
           format: format,
           color: color,
           rendered: nil,
           source_preview: source,
           error: "mmdflux executable was not found on PATH"
         })}

      executable ->
        execute_mmdflux(executable, source, format, color, source_metadata)
    end
  end

  defp execute_mmdflux(executable, source, format, color, source_metadata) do
    args = ["--format", format, "--color", color]

    tmp_path =
      Path.join(System.tmp_dir!(), "runic-ai-mmdflux-#{System.unique_integer([:positive])}.mmd")

    try do
      task =
        Task.async(fn ->
          File.write!(tmp_path, source)
          System.cmd(executable, args ++ [tmp_path], stderr_to_stdout: true)
        end)

      case Task.yield(task, @mmdflux_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, exit_status}} ->
          {:ok,
           Map.merge(source_metadata, %{
             status: if(exit_status == 0, do: :pass, else: :fail),
             command: "mmdflux #{Enum.join(args, " ")}",
             format: format,
             color: color,
             exit_status: exit_status,
             rendered: truncate_output(output, @mmdflux_max_output_bytes),
             truncated?: byte_size(output) > @mmdflux_max_output_bytes,
             source_preview: source
           })}

        {:exit, reason} ->
          {:error,
           Error.from_reason(reason, source: __MODULE__, message: "mmdflux execution failed")}

        nil ->
          {:ok,
           Map.merge(source_metadata, %{
             status: :fail,
             command: "mmdflux #{Enum.join(args, " ")}",
             format: format,
             color: color,
             rendered: nil,
             error: "mmdflux timed out after #{@mmdflux_timeout_ms}ms",
             source_preview: source
           })}
      end
    after
      File.rm(tmp_path)
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, kind: :unexpected, source: __MODULE__)}
  end

  defp mmdflux_format("default"), do: {:ok, "text"}
  defp mmdflux_format("terminal"), do: {:ok, "text"}
  defp mmdflux_format("ansi"), do: {:ok, "text"}
  defp mmdflux_format(format) when format in ["svg", "mmds", "mermaid"], do: {:ok, "text"}
  defp mmdflux_format(format) when format in @mmdflux_formats, do: {:ok, format}

  defp mmdflux_format(format) do
    {:error,
     Error.validation("unsupported mmdflux format",
       source: __MODULE__,
       details: %{format: format, valid_formats: @mmdflux_formats}
     )}
  end

  defp mmdflux_color("never"), do: {:ok, "off"}
  defp mmdflux_color("default"), do: {:ok, "auto"}
  defp mmdflux_color(color) when color in @mmdflux_colors, do: {:ok, color}

  defp mmdflux_color(color) do
    {:error,
     Error.validation("unsupported mmdflux color",
       source: __MODULE__,
       details: %{color: color, valid_colors: @mmdflux_colors}
     )}
  end

  defp truncate_output(output, max_bytes) when byte_size(output) <= max_bytes, do: output

  defp truncate_output(output, max_bytes) do
    output
    |> binary_part(0, max_bytes)
    |> valid_utf8_prefix()
  end

  defp valid_utf8_prefix(output) do
    if String.valid?(output) do
      output
    else
      output
      |> binary_part(0, byte_size(output) - 1)
      |> valid_utf8_prefix()
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
             text: line_preview(text),
             text_truncated?: text_truncated?(text),
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
              text: line_preview(line),
              text_truncated?: text_truncated?(line),
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
    |> Enum.map(fn {line, current} -> context_entry(line, current) end)
  end

  defp context(lines, line_no, count) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {_line, current} -> current > line_no and current <= line_no + count end)
    |> Enum.map(fn {line, current} -> context_entry(line, current) end)
  end

  defp context_entry(line, line_no) do
    %{
      line: line_no,
      text: line_preview(line),
      text_truncated?: text_truncated?(line)
    }
  end

  defp line_preview(line), do: truncate_output(line, @default_search_line_max_bytes)
  defp text_truncated?(line), do: byte_size(line) > @default_search_line_max_bytes

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
