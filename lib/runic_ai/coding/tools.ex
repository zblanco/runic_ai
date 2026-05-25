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
  alias RunicAI.Context.Focus
  alias RunicAI.Context.Ref
  alias RunicAI.Error
  alias RunicAI.Browser.Session, as: BrowserSession
  alias RunicAI.Media
  alias RunicAI.Memory.Entry, as: MemoryEntry
  alias RunicAI.Memory.LocalStore, as: MemoryLocalStore
  alias RunicAI.Memory.Query, as: MemoryQuery
  alias RunicAI.Memory.ReadResult
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store, as: SQLiteStore
  alias RunicAI.Terminal.Event, as: TerminalEvent
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry
  alias RunicAI.Wait
  alias RunicAI.Web

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
    memory_store = Keyword.get(opts, :memory_store, MemoryLocalStore)

    memory_store_opts =
      case Keyword.get(opts, :memory_store_opts, namespace: workspace.root) do
        opts when is_list(opts) -> Keyword.put_new(opts, :namespace, workspace.root)
        _other -> [namespace: workspace.root]
      end

    session_store = Keyword.get(opts, :session_store)
    web_opts = Keyword.get(opts, :web_opts, [])
    media_opts = Keyword.get(opts, :media_opts, [])
    event_sink = Keyword.get(opts, :event_sink)
    browser_opts = Keyword.get(opts, :browser_opts, []) |> put_tool_event_sink(event_sink)
    delegate_opts = Keyword.get(opts, :delegate_opts, [])

    tools =
      workspace
      |> read_tools()
      |> Kernel.++(patch_tools(workspace, patch_dry_run?))
      |> Kernel.++(command_tools(workspace, command_policy, event_sink))
      |> Kernel.++(code_execution_tools(workspace, command_policy, event_sink))
      |> Kernel.++(git_tools(workspace, command_policy, event_sink))
      |> Kernel.++(profile_tools(workspace, command_policy, event_sink))
      |> Kernel.++(process_tools(workspace, command_policy, process_registry, event_sink))
      |> Kernel.++(memory_tools(workspace, memory_store, memory_store_opts, session_store))
      |> Kernel.++(web_tools(workspace, web_opts))
      |> Kernel.++(media_tools(workspace, media_opts))
      |> Kernel.++(browser_tools(workspace, browser_opts, media_opts))
      |> Kernel.++(orchestration_tools(workspace, delegate_opts, session_store))

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
  def run_command(%Workspace{} = workspace, args, policy \\ nil, opts \\ []) when is_map(args) do
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

    CommandRunner.run(workspace, command_input,
      policy: policy,
      event_sink: Keyword.get(opts, :event_sink)
    )
  end

  @spec execute_code(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil, keyword()) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def execute_code(%Workspace{} = workspace, args, policy \\ nil, opts \\ []) when is_map(args) do
    runtime = arg(args, :runtime, "bash")
    code = arg(args, :code, arg(args, :source, nil))

    with {:ok, runtime} <- code_runtime(runtime),
         {:ok, code} <- non_empty_string(code, :code) do
      network = normalize_map(arg(args, :network, %{enabled: false}))
      timeout_ms = arg(args, :timeout_ms, 10_000)

      policy =
        case policy do
          nil ->
            CommandPolicy.new!(
              allowed_commands: ["just_bash"],
              allow_shell: false,
              allow_just_bash: true,
              timeout_ms: timeout_ms,
              max_output_bytes: arg(args, :max_output_bytes, 16_384),
              metadata: %{sandbox_backend: :just_bash, runtime: runtime}
            )

          policy ->
            policy
        end

      command_args = %{
        backend: :just_bash,
        command: "just_bash",
        shell: code,
        timeout_ms: timeout_ms,
        metadata: %{
          runtime: runtime,
          sandbox_backend: :just_bash,
          isolation_level: :in_process_virtual,
          network: network,
          cwd: arg(args, :sandbox_cwd, "/workspace"),
          files: normalize_map(arg(args, :files, %{}))
        }
      }

      with {:ok, %CommandResult{} = result} <- run_command(workspace, command_args, policy, opts) do
        {:ok,
         %{
           result
           | metadata:
               Map.merge(result.metadata, %{
                 tool: :execute_code,
                 runtime: runtime,
                 sandbox_backend: :just_bash,
                 isolation_level: :in_process_virtual,
                 network: network,
                 host_cwd: workspace.root,
                 sandbox_cwd: command_args.metadata.cwd,
                 output_cap_bytes: arg(args, :max_output_bytes, 16_384),
                 changed_artifact_refs: List.wrap(result.artifact_ref) |> Enum.reject(&is_nil/1)
               })
         }}
      end
    end
  end

  @spec sandbox_status(Workspace.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def sandbox_status(%Workspace{} = workspace, args \\ %{}) when is_map(args) do
    {:ok,
     %{
       status: :available,
       workspace_root: workspace.root,
       default_backend: :just_bash,
       backends: [
         %{
           name: :just_bash,
           available?: Code.ensure_loaded?(JustBash),
           runtimes: [:bash],
           isolation_level: :in_process_virtual,
           network: %{enabled: false},
           stateful?: false,
           security_boundary?: false
         }
       ],
       requested_backend: arg(args, :backend, :just_bash)
     }}
  end

  @spec memory_write(Workspace.t(), map(), term(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def memory_write(%Workspace{} = workspace, args, store \\ MemoryLocalStore, store_opts \\ [])
      when is_map(args) and is_list(store_opts) do
    content = arg(args, :content, nil)
    summary = arg(args, :summary, nil)
    kind = normalize_memory_kind(arg(args, :kind, :semantic))
    salience = arg(args, :salience, 0.7)

    metadata =
      args
      |> arg(:metadata, %{})
      |> normalize_map()
      |> Map.put_new(:workspace_root, workspace.root)
      |> Map.put_new(:source, :memory_write_tool)

    with {:ok, content} <- non_empty_string(content, :content),
         {:ok, entry} <-
           MemoryEntry.new(
             id: arg(args, :id, "memory-#{System.unique_integer([:positive])}"),
             kind: kind,
             content: content,
             summary: summary,
             refs: [],
             salience: salience,
             metadata: metadata
           ),
         {:ok, write_result} <- memory_store_write(store, [entry], store_opts) do
      {:ok,
       %{
         status: :written,
         count: 1,
         namespace: Keyword.get(store_opts, :namespace, workspace.root),
         entries: [memory_entry_map(entry)],
         store: memory_store_label(store),
         store_result: write_result
       }}
    end
  end

  @spec memory_recall(Workspace.t(), map(), term(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def memory_recall(%Workspace{} = workspace, args, store \\ MemoryLocalStore, store_opts \\ [])
      when is_map(args) and is_list(store_opts) do
    focus_text = arg(args, :query, arg(args, :focus, arg(args, :goal, "")))
    limit = arg(args, :limit, 6)

    with {:ok, focus_text} <- non_empty_string(focus_text, :query),
         {:ok, limit} <- positive_integer(limit, :limit),
         {:ok, focus} <-
           Focus.new(
             goal: focus_text,
             questions: string_list_or_empty(arg(args, :questions, [])),
             entities: string_list_or_empty(arg(args, :entities, [])),
             constraints: string_list_or_empty(arg(args, :constraints, [])),
             metadata: %{workspace_root: workspace.root}
           ),
         {:ok, kinds} <- memory_kinds(arg(args, :kinds, [:episodic, :semantic, :temporal])),
         {:ok, query} <- MemoryQuery.new(focus: focus, kinds: kinds, limit: limit),
         {:ok, %ReadResult{} = result} <- memory_store_read(store, query, store_opts) do
      {:ok,
       %{
         status: :ok,
         query: focus_text,
         count: length(result.entries),
         entries: Enum.map(result.entries, &memory_entry_map/1),
         refs: Enum.map(result.refs, &context_ref_map/1),
         metadata: result.metadata,
         store: memory_store_label(store)
       }}
    end
  end

  @spec session_search(Workspace.t(), map(), SQLiteStore.t() | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def session_search(%Workspace{} = workspace, args, session_store \\ nil) when is_map(args) do
    query = arg(args, :query, nil)
    limit = arg(args, :limit, 8)

    with {:ok, query} <- non_empty_string(query, :query),
         {:ok, limit} <- positive_integer(limit, :limit) do
      case session_store do
        %SQLiteStore{} = store ->
          events =
            store
            |> Queries.search_events(query)
            |> Enum.take(limit)
            |> Enum.map(&session_event_map/1)

          {:ok,
           %{
             status: :ok,
             query: query,
             workspace_root: workspace.root,
             count: length(events),
             results: events,
             source_refs: Enum.map(events, & &1.source_ref)
           }}

        _other ->
          {:ok,
           %{
             status: :unavailable,
             query: query,
             workspace_root: workspace.root,
             count: 0,
             results: [],
             source_refs: [],
             diagnostic: "session_search requires a SQLite persistence store"
           }}
      end
    end
  end

  @spec web_search(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def web_search(%Workspace{} = workspace, args, opts \\ [])
      when is_map(args) and is_list(opts) do
    query = arg(args, :query, nil)

    with {:ok, query} <- non_empty_string(query, :query),
         {:ok, result} <- Web.search(query, args, opts) do
      result =
        result
        |> Map.put(:artifact_ref, persist_tool_artifact(workspace, :web_search, result))

      {:ok, result}
    end
  end

  @spec web_extract(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def web_extract(%Workspace{} = workspace, args, opts \\ [])
      when is_map(args) and is_list(opts) do
    url = arg(args, :url, nil)

    with {:ok, url} <- non_empty_string(url, :url),
         {:ok, result} <- Web.extract(url, args, opts) do
      artifact_ref = persist_tool_artifact(workspace, :web_extract, result.source)
      {:ok, put_in(result, [:source, :artifact_ref], artifact_ref)}
    end
  end

  @spec vision_analyze(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def vision_analyze(%Workspace{} = workspace, args, opts \\ [])
      when is_map(args) and is_list(opts) do
    with {:ok, input} <- media_image_input(workspace, args),
         {:ok, result} <- Media.vision_analyze(input, media_call_opts(args, opts)) do
      {:ok, maybe_persist_text_artifact(workspace, :vision_analysis, result, :text)}
    end
  end

  @spec image_generate(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def image_generate(%Workspace{} = workspace, args, opts \\ [])
      when is_map(args) and is_list(opts) do
    prompt = arg(args, :prompt, nil)

    with {:ok, prompt} <- non_empty_string(prompt, :prompt),
         {:ok, result} <- Media.generate_image(prompt, media_call_opts(args, opts)) do
      {:ok, persist_media_binary(workspace, :generated_image, result, :image, "image/png")}
    end
  end

  @spec speech_generate(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def speech_generate(%Workspace{} = workspace, args, opts \\ [])
      when is_map(args) and is_list(opts) do
    text = arg(args, :text, nil)

    with {:ok, text} <- non_empty_string(text, :text),
         {:ok, result} <- Media.speak(text, media_call_opts(args, opts)) do
      media_type = Map.get(result, :media_type, "audio/mpeg")
      {:ok, persist_media_binary(workspace, :speech_audio, result, :audio, media_type)}
    end
  end

  @spec transcribe_audio(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def transcribe_audio(%Workspace{} = workspace, args, opts \\ [])
      when is_map(args) and is_list(opts) do
    with {:ok, audio} <- media_binary_input(workspace, args, :audio),
         {:ok, result} <- Media.transcribe(audio, media_call_opts(args, opts)) do
      {:ok, maybe_persist_text_artifact(workspace, :transcription, result, :text)}
    end
  end

  @spec ocr_document(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def ocr_document(%Workspace{} = workspace, args, opts \\ [])
      when is_map(args) and is_list(opts) do
    with {:ok, document} <- media_binary_input(workspace, args, :document),
         {:ok, result} <- Media.ocr(document, media_call_opts(args, opts)) do
      {:ok, maybe_persist_text_artifact(workspace, :ocr_markdown, result, :markdown)}
    end
  end

  @spec browser_navigate(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def browser_navigate(%Workspace{}, args, opts \\ []) when is_map(args) and is_list(opts) do
    url = arg(args, :url, nil)

    with {:ok, url} <- non_empty_string(url, :url),
         {:ok, session} <- browser_session(opts) do
      BrowserSession.navigate(session, url, args, event_sink_opts(opts))
    end
  end

  @spec browser_snapshot(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def browser_snapshot(%Workspace{}, args, opts \\ []) when is_map(args) and is_list(opts) do
    with {:ok, session} <- browser_session(opts),
         do: BrowserSession.snapshot(session, args, event_sink_opts(opts))
  end

  @spec browser_click(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def browser_click(%Workspace{}, args, opts \\ []) when is_map(args) and is_list(opts) do
    selector = arg(args, :selector, arg(args, :ref, nil))

    with {:ok, selector} <- non_empty_string(selector, :selector),
         {:ok, session} <- browser_session(opts) do
      BrowserSession.click(session, selector, args, event_sink_opts(opts))
    end
  end

  @spec browser_type(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def browser_type(%Workspace{}, args, opts \\ []) when is_map(args) and is_list(opts) do
    selector = arg(args, :selector, arg(args, :ref, nil))
    text = arg(args, :text, nil)

    with {:ok, selector} <- non_empty_string(selector, :selector),
         {:ok, text} <- non_empty_string(text, :text),
         {:ok, session} <- browser_session(opts) do
      BrowserSession.type(session, selector, text, args, event_sink_opts(opts))
    end
  end

  @spec browser_press(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def browser_press(%Workspace{}, args, opts \\ []) when is_map(args) and is_list(opts) do
    key = arg(args, :key, nil)

    with {:ok, key} <- non_empty_string(key, :key),
         {:ok, session} <- browser_session(opts) do
      BrowserSession.press(session, key, args, event_sink_opts(opts))
    end
  end

  @spec browser_scroll(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def browser_scroll(%Workspace{}, args, opts \\ []) when is_map(args) and is_list(opts) do
    with {:ok, session} <- browser_session(opts),
         do: BrowserSession.scroll(session, args, event_sink_opts(opts))
  end

  @spec browser_console(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def browser_console(%Workspace{}, args, opts \\ []) when is_map(args) and is_list(opts) do
    with {:ok, session} <- browser_session(opts),
         do: BrowserSession.console(session, args, event_sink_opts(opts))
  end

  @spec browser_screenshot(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def browser_screenshot(%Workspace{} = workspace, args, opts \\ [])
      when is_map(args) and is_list(opts) do
    with {:ok, session} <- browser_session(opts),
         {:ok, result} <- BrowserSession.screenshot(session, args, event_sink_opts(opts)) do
      {:ok, persist_media_binary(workspace, :browser_screenshot, result, :image, "image/png")}
    end
  end

  @spec browser_vision(Workspace.t(), map(), keyword(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def browser_vision(%Workspace{} = workspace, args, browser_opts \\ [], media_opts \\ [])
      when is_map(args) and is_list(browser_opts) and is_list(media_opts) do
    with {:ok, session} <- browser_session(browser_opts),
         {:ok, raw_screenshot} <-
           BrowserSession.screenshot(session, args, event_sink_opts(browser_opts)),
         screenshot <-
           persist_media_binary(
             workspace,
             :browser_screenshot,
             raw_screenshot,
             :image,
             "image/png"
           ),
         image when is_binary(image) <- Map.get(raw_screenshot, :image),
         {:ok, result} <-
           Media.vision_analyze(
             %{
               prompt: arg(args, :prompt, "Analyze this browser screenshot."),
               image: image,
               media_type: Map.get(screenshot, :media_type, "image/png")
             },
             media_call_opts(args, media_opts)
           ) do
      {:ok,
       result
       |> Map.put(:screenshot_artifact_ref, Map.get(screenshot, :artifact_ref))
       |> Map.put(:browser_url, Map.get(screenshot, :url))}
    else
      nil ->
        {:error,
         Error.validation("browser screenshot did not include image data", source: __MODULE__)}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec clarify(Workspace.t(), map()) :: {:ok, Wait.t()} | {:error, Error.t()}
  def clarify(%Workspace{} = workspace, args) when is_map(args) do
    question = arg(args, :question, nil)

    with {:ok, question} <- non_empty_string(question, :question) do
      {:ok,
       Wait.new!(:clarify,
         reason: :user_input_required,
         payload: %{
           question: question,
           choices: string_list_or_empty(arg(args, :choices, [])),
           default: arg(args, :default, nil)
         },
         details: %{workspace_root: workspace.root},
         metadata: %{tool: :clarify, toolset: :clarify}
       )}
    end
  end

  @spec delegate_task(Workspace.t(), map(), keyword(), SQLiteStore.t() | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def delegate_task(%Workspace{} = workspace, args, opts \\ [], session_store \\ nil)
      when is_map(args) and is_list(opts) do
    objective = arg(args, :objective, nil)

    with {:ok, objective} <- non_empty_string(objective, :objective),
         {:ok, result} <- run_delegate(workspace, objective, args, opts),
         :ok <- record_delegate_events(session_store, args, objective, result) do
      {:ok, result}
    end
  end

  @spec git_status(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil, keyword()) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_status(workspace, args \\ %{}, policy \\ nil, opts \\ []) do
    run_git(workspace, ["status", "--short", "--branch"], args, policy, opts)
  end

  @spec git_diff(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil, keyword()) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_diff(workspace, args \\ %{}, policy \\ nil, opts \\ []) do
    extra =
      case arg(args, :path, nil) do
        nil -> []
        path -> ["--", path]
      end

    run_git(workspace, ["diff" | extra], args, policy, opts)
  end

  @spec git_log(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil, keyword()) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_log(workspace, args \\ %{}, policy \\ nil, opts \\ []) do
    limit = arg(args, :limit, 20)

    with {:ok, limit} <- positive_integer(limit, :limit) do
      run_git(workspace, ["log", "--oneline", "-n", Integer.to_string(limit)], args, policy, opts)
    end
  end

  @spec git_show(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil, keyword()) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_show(workspace, args, policy \\ nil, opts \\ []) do
    ref = arg(args, :ref, "HEAD")
    run_git(workspace, ["show", "--stat", "--patch", ref], args, policy, opts)
  end

  @spec git_branch(Workspace.t(), map(), CommandPolicy.t() | keyword() | map() | nil, keyword()) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def git_branch(workspace, args \\ %{}, policy \\ nil, opts \\ []) do
    run_git(workspace, ["branch", "--show-current"], args, policy, opts)
  end

  @spec run_profile_task(
          Workspace.t(),
          Profile.task(),
          map(),
          CommandPolicy.t() | keyword() | map() | nil,
          keyword()
        ) ::
          {:ok, RunicAI.Coding.CommandResult.t()} | {:error, Error.t()}
  def run_profile_task(%Workspace{} = workspace, task, args \\ %{}, policy \\ nil, opts \\ []) do
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
        policy,
        opts
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

  @spec project_command(
          Workspace.t(),
          map(),
          CommandPolicy.t() | keyword() | map() | nil,
          keyword()
        ) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def project_command(%Workspace{} = workspace, args, policy \\ nil, opts \\ [])
      when is_map(args) do
    cond do
      task = arg(args, :task, nil) ->
        run_profile_task(workspace, normalize_profile_task(task), args, policy, opts)

      argv = arg(args, :argv, nil) ->
        run_command(workspace, Map.put(args, :argv, argv), policy, opts)

      command = arg(args, :command, nil) ->
        run_command(workspace, put_project_command(args, command), policy, opts)

      true ->
        {:error,
         Error.validation("project command requires task, argv, or command",
           source: __MODULE__,
           details: %{args: args}
         )}
    end
  end

  defp put_project_command(args, command) when is_binary(command) do
    if arg(args, :args, []) == [] do
      args
      |> Map.delete(:command)
      |> Map.delete("command")
      |> Map.put(:argv, OptionParser.split(command))
    else
      Map.put(args, :command, command)
    end
  end

  @spec runtime_smoke(
          Workspace.t(),
          map(),
          CommandPolicy.t() | keyword() | map() | nil,
          keyword()
        ) ::
          {:ok, CommandResult.t()} | {:error, Error.t()}
  def runtime_smoke(%Workspace{} = workspace, args, policy \\ nil, opts \\ [])
      when is_map(args) do
    adapter = arg(args, :adapter, workspace.profile.name)

    case adapter do
      :mix ->
        mix_runtime_smoke(workspace, args, policy, opts)

      "mix" ->
        mix_runtime_smoke(workspace, args, policy, opts)

      _other ->
        project_command(workspace, args, policy, opts)
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
        %{category: :coding, toolset: :file, mutates?: false}
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
        %{category: :coding, toolset: :file, mutates?: false}
      ),
      definition(
        "read_file",
        "Read one workspace text file with hash and truncation metadata.",
        [
          path: [type: :string, required: true],
          max_bytes: [type: :pos_integer]
        ],
        fn args -> read_file(workspace, args) end,
        %{category: :coding, toolset: :file, mutates?: false}
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
        %{category: :coding, toolset: :file, mutates?: false}
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
        %{category: :coding, toolset: :file, mutates?: false}
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
        %{category: :coding, toolset: :file, mutates?: false}
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
        %{category: :coding, toolset: :file, mutates?: false}
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
        %{category: :coding_visualization, toolset: :file, mutates?: false}
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
        %{category: :coding_visualization, toolset: :file, mutates?: false}
      ),
      definition(
        "source_assert",
        "Evaluate deterministic source assertions against workspace files.",
        [
          checks: [type: :any, required: true],
          context: [type: :any]
        ],
        fn args -> source_assert(workspace, args) end,
        %{category: :coding_verify, toolset: :verify, mutates?: false}
      ),
      definition(
        "changed_file_inventory",
        "Report file metadata and hashes for selected or discovered workspace files.",
        [
          paths: [type: {:list, :string}, default: []],
          include_hashes: [type: :boolean, default: true]
        ],
        fn args -> changed_file_inventory(workspace, args) end,
        %{category: :coding_verify, toolset: :verify, mutates?: false}
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
        %{category: :coding, toolset: :patch, mutates?: true, requires_review?: true},
        timeout: 30_000,
        stop_on_error: true
      )
    ]
  end

  defp command_tools(workspace, command_policy, event_sink) do
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
        fn args -> run_command(workspace, args, command_policy, event_sink: event_sink) end,
        %{
          category: :coding,
          toolset: :terminal,
          mutates?: :command_dependent,
          requires_review?: true
        },
        timeout: :infinity,
        stop_on_error: false
      )
    ]
  end

  defp code_execution_tools(workspace, command_policy, event_sink) do
    [
      definition(
        "execute_code",
        "Execute a bounded code snippet in a configured sandbox backend. The initial backend is just_bash and is an in-process virtual runtime, not a hard security boundary.",
        [
          runtime: [type: :string, default: "bash"],
          code: [type: :string, required: true],
          timeout_ms: [type: :pos_integer],
          max_output_bytes: [type: :pos_integer],
          files: [type: :any],
          network: [type: :any]
        ],
        fn args -> execute_code(workspace, args, command_policy, event_sink: event_sink) end,
        %{
          category: :coding_code_execution,
          toolset: :code_execution,
          mutates?: :sandbox_dependent,
          requires_review?: true,
          sandbox_backend: :just_bash,
          isolation_level: :in_process_virtual
        },
        timeout: :infinity,
        stop_on_error: false
      ),
      definition(
        "sandbox_status",
        "Describe configured local sandbox/code-execution backends and their isolation metadata.",
        [backend: [type: :string]],
        fn args -> sandbox_status(workspace, args) end,
        %{
          category: :coding_code_execution,
          toolset: :code_execution,
          mutates?: false,
          requires_review?: false
        }
      )
    ]
  end

  defp git_tools(workspace, command_policy, event_sink) do
    [
      definition(
        "git_status",
        "Read git status for the workspace.",
        [],
        fn args -> git_status(workspace, args, command_policy, event_sink: event_sink) end,
        %{category: :coding_git, toolset: :git, mutates?: false}
      ),
      definition(
        "git_diff",
        "Read git diff for the workspace or one path.",
        [path: [type: :string]],
        fn args -> git_diff(workspace, args, command_policy, event_sink: event_sink) end,
        %{category: :coding_git, toolset: :git, mutates?: false}
      ),
      definition(
        "git_log",
        "Read recent git log entries.",
        [limit: [type: :pos_integer, default: 20]],
        fn args -> git_log(workspace, args, command_policy, event_sink: event_sink) end,
        %{category: :coding_git, toolset: :git, mutates?: false}
      ),
      definition(
        "git_show",
        "Read one git revision with stat and patch.",
        [ref: [type: :string, default: "HEAD"]],
        fn args -> git_show(workspace, args, command_policy, event_sink: event_sink) end,
        %{category: :coding_git, toolset: :git, mutates?: false}
      ),
      definition(
        "git_branch",
        "Read current git branch name.",
        [],
        fn args -> git_branch(workspace, args, command_policy, event_sink: event_sink) end,
        %{category: :coding_git, toolset: :git, mutates?: false}
      )
    ]
  end

  defp profile_tools(workspace, command_policy, event_sink) do
    [
      definition(
        "compile_project",
        "Run the detected project compile command.",
        [args: [type: {:list, :string}, default: []], cwd: [type: :string, default: "."]],
        fn args ->
          run_profile_task(workspace, :compile_project, args, command_policy,
            event_sink: event_sink
          )
        end,
        %{category: :coding_profile, toolset: :profile, mutates?: :profile_dependent}
      ),
      definition(
        "run_tests",
        "Run the detected project test command.",
        [args: [type: {:list, :string}, default: []], cwd: [type: :string, default: "."]],
        fn args ->
          run_profile_task(workspace, :run_tests, args, command_policy, event_sink: event_sink)
        end,
        %{category: :coding_profile, toolset: :profile, mutates?: :profile_dependent}
      ),
      definition(
        "run_formatter",
        "Run the detected project formatter command.",
        [args: [type: {:list, :string}, default: []], cwd: [type: :string, default: "."]],
        fn args ->
          run_profile_task(workspace, :run_formatter, args, command_policy,
            event_sink: event_sink
          )
        end,
        %{category: :coding_profile, toolset: :profile, mutates?: true, requires_review?: true}
      ),
      definition(
        "run_linter",
        "Run the detected project lint/check command.",
        [args: [type: {:list, :string}, default: []], cwd: [type: :string, default: "."]],
        fn args ->
          run_profile_task(workspace, :run_linter, args, command_policy, event_sink: event_sink)
        end,
        %{category: :coding_profile, toolset: :profile, mutates?: false}
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
          timeout_ms: [type: :pos_integer],
          metadata: [type: :any]
        ],
        fn args -> project_command(workspace, args, command_policy, event_sink: event_sink) end,
        %{category: :coding_profile, toolset: :profile, mutates?: :profile_dependent}
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
        fn args -> runtime_smoke(workspace, args, command_policy, event_sink: event_sink) end,
        %{category: :coding_profile, toolset: :profile, mutates?: :profile_dependent}
      )
    ]
  end

  defp process_tools(_workspace, _command_policy, nil, _event_sink), do: []

  defp process_tools(workspace, command_policy, process_registry, event_sink) do
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
            policy: command_policy,
            event_sink: event_sink
          )
        end,
        %{
          category: :coding_process,
          toolset: :process,
          mutates?: :command_dependent,
          requires_review?: true
        }
      ),
      definition(
        "process_poll",
        "Poll a managed background process.",
        [id: [type: :string, required: true]],
        fn args -> ProcessRegistry.poll(process_registry, arg(args, :id, nil)) end,
        %{category: :coding_process, toolset: :process, mutates?: false}
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
        %{category: :coding_process, toolset: :process, mutates?: false}
      ),
      definition(
        "process_write",
        "Write stdin to a managed background process.",
        [id: [type: :string, required: true], input: [type: :string, required: true]],
        fn args ->
          ProcessRegistry.write(process_registry, arg(args, :id, nil), arg(args, :input, ""))
        end,
        %{category: :coding_process, toolset: :process, mutates?: true, requires_review?: true}
      ),
      definition(
        "process_kill",
        "Kill a managed background process.",
        [id: [type: :string, required: true]],
        fn args -> ProcessRegistry.kill(process_registry, arg(args, :id, nil)) end,
        %{category: :coding_process, toolset: :process, mutates?: true, requires_review?: true}
      )
    ]
  end

  defp memory_tools(workspace, memory_store, memory_store_opts, session_store) do
    [
      definition(
        "memory_write",
        "Write an explicit local memory fact with provenance metadata for later recall.",
        [
          content: [type: :string, required: true],
          summary: [type: :string],
          kind: [type: :string, default: "semantic"],
          salience: [type: :any],
          metadata: [type: :any]
        ],
        fn args -> memory_write(workspace, args, memory_store, memory_store_opts) end,
        %{category: :memory, toolset: :memory, mutates?: true, requires_review?: true},
        stop_on_error: false
      ),
      definition(
        "memory_recall",
        "Recall explicit local memory entries by focus/query.",
        [
          query: [type: :string, required: true],
          kinds: [type: {:list, :string}],
          limit: [type: :pos_integer],
          questions: [type: {:list, :string}],
          entities: [type: {:list, :string}],
          constraints: [type: {:list, :string}]
        ],
        fn args -> memory_recall(workspace, args, memory_store, memory_store_opts) end,
        %{category: :memory, toolset: :memory, mutates?: false}
      ),
      definition(
        "session_search",
        "Search prior persisted RunicAI sessions/events and return compact source-cited results.",
        [query: [type: :string, required: true], limit: [type: :pos_integer]],
        fn args -> session_search(workspace, args, session_store) end,
        %{category: :session_search, toolset: :session_search, mutates?: false}
      )
    ]
  end

  defp web_tools(workspace, web_opts) do
    [
      definition(
        "web_search",
        "Search configured web providers and return compact source-cited records.",
        [
          query: [type: :string, required: true],
          limit: [type: :pos_integer],
          provider: [type: :string]
        ],
        fn args -> web_search(workspace, args, web_opts) end,
        %{category: :web, toolset: :web, mutates?: false}
      ),
      definition(
        "web_extract",
        "Extract one URL or provided HTML body into capped markdown with provenance.",
        [
          url: [type: :string, required: true],
          html: [type: :string],
          markdown: [type: :string],
          title: [type: :string],
          max_bytes: [type: :pos_integer]
        ],
        fn args -> web_extract(workspace, args, web_opts) end,
        %{category: :web, toolset: :web, mutates?: false}
      )
    ]
  end

  defp media_tools(workspace, media_opts) do
    [
      definition(
        "vision_analyze",
        "Analyze an image path, image URL, or base64 image with the configured vision model.",
        [
          prompt: [type: :string, required: true],
          image_path: [type: :string],
          image_url: [type: :string],
          image_base64: [type: :string],
          media_type: [type: :string],
          model: [type: :string]
        ],
        fn args -> vision_analyze(workspace, args, media_opts) end,
        %{category: :media, toolset: :media, mutates?: false}
      ),
      definition(
        "image_generate",
        "Generate an image through the configured media provider and store the binary as an artifact when available.",
        [
          prompt: [type: :string, required: true],
          model: [type: :string],
          output_path: [type: :string],
          size: [type: :string]
        ],
        fn args -> image_generate(workspace, args, media_opts) end,
        %{category: :media, toolset: :media, mutates?: false, requires_review?: true},
        timeout: :infinity
      ),
      definition(
        "speech_generate",
        "Generate speech audio from text and store the audio as an artifact when available.",
        [
          text: [type: :string, required: true],
          model: [type: :string],
          voice: [type: :string],
          output_format: [type: :string]
        ],
        fn args -> speech_generate(workspace, args, media_opts) end,
        %{category: :media, toolset: :media, mutates?: false, requires_review?: true},
        timeout: :infinity
      ),
      definition(
        "transcribe_audio",
        "Transcribe an audio file path or base64 audio payload into text.",
        [
          audio_path: [type: :string],
          audio_base64: [type: :string],
          media_type: [type: :string],
          model: [type: :string],
          language: [type: :string]
        ],
        fn args -> transcribe_audio(workspace, args, media_opts) end,
        %{category: :media, toolset: :media, mutates?: false},
        timeout: :infinity
      ),
      definition(
        "ocr_document",
        "Run OCR over a document/image path or base64 payload and return markdown.",
        [
          document_path: [type: :string],
          document_base64: [type: :string],
          document_type: [type: :string],
          model: [type: :string]
        ],
        fn args -> ocr_document(workspace, args, media_opts) end,
        %{category: :media, toolset: :media, mutates?: false},
        timeout: :infinity
      )
    ]
  end

  defp browser_tools(workspace, browser_opts, media_opts) do
    [
      definition(
        "browser_navigate",
        "Navigate the agent browser session to a URL.",
        [url: [type: :string, required: true]],
        fn args -> browser_navigate(workspace, args, browser_opts) end,
        %{category: :browser, toolset: :browser, mutates?: :browser_state}
      ),
      definition(
        "browser_snapshot",
        "Capture a compact accessibility snapshot and stable element refs from the agent browser.",
        [],
        fn args -> browser_snapshot(workspace, args, browser_opts) end,
        %{category: :browser, toolset: :browser, mutates?: false}
      ),
      definition(
        "browser_click",
        "Click an element by snapshot ref or selector in the agent browser.",
        [selector: [type: :string], ref: [type: :string]],
        fn args -> browser_click(workspace, args, browser_opts) end,
        %{category: :browser, toolset: :browser, mutates?: :browser_state, requires_review?: true}
      ),
      definition(
        "browser_type",
        "Type or fill text into an element by snapshot ref or selector in the agent browser.",
        [selector: [type: :string], ref: [type: :string], text: [type: :string, required: true]],
        fn args -> browser_type(workspace, args, browser_opts) end,
        %{category: :browser, toolset: :browser, mutates?: :browser_state, requires_review?: true}
      ),
      definition(
        "browser_press",
        "Press a key in the agent browser.",
        [key: [type: :string, required: true]],
        fn args -> browser_press(workspace, args, browser_opts) end,
        %{category: :browser, toolset: :browser, mutates?: :browser_state}
      ),
      definition(
        "browser_scroll",
        "Scroll the agent browser viewport.",
        [direction: [type: :string], amount: [type: :pos_integer]],
        fn args -> browser_scroll(workspace, args, browser_opts) end,
        %{category: :browser, toolset: :browser, mutates?: :browser_state}
      ),
      definition(
        "browser_console",
        "Read agent browser console events.",
        [limit: [type: :pos_integer]],
        fn args -> browser_console(workspace, args, browser_opts) end,
        %{category: :browser, toolset: :browser, mutates?: false}
      ),
      definition(
        "browser_screenshot",
        "Capture an agent browser screenshot and store it as an artifact when persistence is enabled.",
        [path: [type: :string]],
        fn args -> browser_screenshot(workspace, args, browser_opts) end,
        %{category: :browser, toolset: :browser, mutates?: false}
      ),
      definition(
        "browser_vision",
        "Capture an agent browser screenshot and analyze it through the configured media vision model.",
        [prompt: [type: :string], path: [type: :string], model: [type: :string]],
        fn args -> browser_vision(workspace, args, browser_opts, media_opts) end,
        %{category: :browser, toolset: :browser, mutates?: false},
        timeout: :infinity
      )
    ]
  end

  defp orchestration_tools(workspace, delegate_opts, session_store) do
    [
      definition(
        "clarify",
        "Pause the run and ask the operator a focused clarification question.",
        [
          question: [type: :string, required: true],
          choices: [type: {:list, :string}],
          default: [type: :string]
        ],
        fn args -> clarify(workspace, args) end,
        %{category: :orchestration, toolset: :clarify, mutates?: false}
      ),
      definition(
        "delegate_task",
        "Launch or simulate a restricted child task and return only the compact final summary and refs.",
        [
          objective: [type: :string, required: true],
          agent_kind: [type: :string],
          profile: [type: :string],
          toolsets: [type: {:list, :string}],
          context: [type: :any]
        ],
        fn args -> delegate_task(workspace, args, delegate_opts, session_store) end,
        %{
          category: :orchestration,
          toolset: :delegation,
          mutates?: :child_session,
          requires_review?: true
        },
        timeout: :infinity
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
  defp model_output(%Wait{} = wait), do: wait |> Map.from_struct() |> model_output()

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

  defp run_git(workspace, git_args, args, policy, opts) do
    cwd = arg(args, :cwd, ".")
    timeout_ms = arg(args, :timeout_ms, nil)

    git_policy =
      policy
      |> CommandPolicy.from_input!()
      |> Map.put(:allowed_commands, ["git"])

    run_command(
      workspace,
      %{argv: ["git" | git_args], cwd: cwd, timeout_ms: timeout_ms},
      git_policy,
      opts
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

  defp code_runtime(runtime) when runtime in [:bash, "bash", :sh, "sh"], do: {:ok, :bash}

  defp code_runtime(runtime) do
    {:error,
     Error.validation("unsupported code execution runtime",
       source: __MODULE__,
       details: %{runtime: runtime, supported_runtimes: [:bash]}
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

  defp normalize_memory_kind(kind) when kind in [:episodic, :semantic, :temporal], do: kind

  defp normalize_memory_kind(kind) when is_binary(kind) do
    case kind |> String.downcase() |> String.replace("-", "_") do
      "episodic" -> :episodic
      "semantic" -> :semantic
      "temporal" -> :temporal
      _other -> :semantic
    end
  end

  defp normalize_memory_kind(_kind), do: :semantic

  defp memory_kinds(nil), do: {:ok, [:episodic, :semantic, :temporal]}
  defp memory_kinds(""), do: {:ok, [:episodic, :semantic, :temporal]}

  defp memory_kinds(values) do
    values =
      values
      |> List.wrap()
      |> Enum.map(&normalize_memory_kind/1)
      |> Enum.uniq()

    invalid = Enum.reject(values, &(&1 in [:episodic, :semantic, :temporal]))

    if invalid == [] do
      {:ok, values}
    else
      {:error,
       Error.validation("memory kinds contain invalid values",
         source: __MODULE__,
         details: %{kinds: values, invalid: invalid}
       )}
    end
  end

  defp string_list_or_empty(nil), do: []
  defp string_list_or_empty(""), do: []

  defp string_list_or_empty(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list_or_empty(value), do: string_list_or_empty([value])

  defp memory_store_write(nil, entries, opts),
    do: memory_store_write(MemoryLocalStore, entries, opts)

  defp memory_store_write({store, store_opts}, entries, opts) when is_list(store_opts),
    do: memory_store_write(store, entries, Keyword.merge(opts, store_opts))

  defp memory_store_write(store, entries, opts) when is_atom(store),
    do: normalize_memory_store_result(store.write(entries, opts))

  defp memory_store_write(store, entries, opts) when is_function(store, 2),
    do: normalize_memory_store_result(store.(entries, opts))

  defp memory_store_write(store, _entries, _opts) do
    {:error,
     Error.validation("memory store must be a module, {module, opts}, function, or nil",
       source: __MODULE__,
       details: %{store: inspect(store)}
     )}
  end

  defp memory_store_read(nil, query, opts),
    do: memory_store_read(MemoryLocalStore, query, opts)

  defp memory_store_read({store, store_opts}, query, opts) when is_list(store_opts),
    do: memory_store_read(store, query, Keyword.merge(opts, store_opts))

  defp memory_store_read(store, query, opts) when is_atom(store),
    do: normalize_memory_store_result(store.read(query, opts))

  defp memory_store_read(store, query, opts) when is_function(store, 2),
    do: normalize_memory_store_result(store.(query, opts))

  defp memory_store_read(store, _query, _opts) do
    {:error,
     Error.validation("memory store must be a module, {module, opts}, function, or nil",
       source: __MODULE__,
       details: %{store: inspect(store)}
     )}
  end

  defp normalize_memory_store_result({:ok, result}), do: {:ok, result}
  defp normalize_memory_store_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_memory_store_result({:error, reason}),
    do: {:error, Error.from_reason(reason, source: __MODULE__)}

  defp normalize_memory_store_result(result), do: {:ok, result}

  defp memory_entry_map(%MemoryEntry{} = entry) do
    %{
      id: entry.id,
      kind: entry.kind,
      content: entry.content,
      summary: entry.summary,
      salience: entry.salience,
      valid_from: datetime_iso(entry.valid_from),
      valid_until: datetime_iso(entry.valid_until),
      refs: Enum.map(entry.refs, &context_ref_map/1),
      metadata: entry.metadata,
      source_ref: "memory:#{entry.id}"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp context_ref_map(%Ref{} = ref) do
    %{
      kind: ref.kind,
      target_id: ref.target_id,
      label: ref.label,
      source_ref: Ref.key(ref),
      provenance: ref.provenance,
      metadata: ref.metadata
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp context_ref_map(ref), do: %{source_ref: to_string(ref)}

  defp memory_store_label(nil), do: :local_ets
  defp memory_store_label(MemoryLocalStore), do: :local_ets
  defp memory_store_label({store, _opts}), do: memory_store_label(store)
  defp memory_store_label(store) when is_atom(store), do: store
  defp memory_store_label(store) when is_function(store), do: :function
  defp memory_store_label(_store), do: :unknown

  defp session_event_map(event) do
    data = event.data_json || %{}
    detail = event.detail || event.title || ""
    snippet = session_event_snippet(event, data)

    %{
      id: event.id,
      source_ref: "terminal_event:#{event.id}",
      session_id: event.session_id,
      run_id: event.run_id || Map.get(data, "run_id") || Map.get(data, :run_id),
      sequence: event.sequence,
      agent: event.agent,
      kind: event.kind,
      phase: event.phase,
      status: event.status,
      title: event.title,
      detail: detail,
      snippet: snippet,
      at: datetime_iso(event.at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp session_event_snippet(event, data) do
    [
      event.title,
      event.detail,
      Map.get(data, "reply_text") || Map.get(data, :reply_text),
      get_in(data, ["output", "text"]) || get_in(data, [:output, :text])
    ]
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> inspect(data, limit: 20, printable_limit: 1_000)
      text -> text
    end
    |> truncate_output(500)
  end

  defp media_call_opts(args, opts) do
    opts =
      opts
      |> maybe_put_arg(:model, args)
      |> maybe_put_arg(:voice, args)
      |> maybe_put_arg(:size, args)
      |> maybe_put_arg(:output_format, args)
      |> maybe_put_arg(:language, args)
      |> maybe_put_arg(:document_type, args)

    opts
  end

  defp media_image_input(%Workspace{} = workspace, args) do
    prompt = arg(args, :prompt, nil)
    media_type = arg(args, :media_type, "image/png")

    cond do
      image_url = arg(args, :image_url, nil) ->
        {:ok, %{prompt: prompt, image_url: image_url, media_type: media_type}}

      image_base64 = arg(args, :image_base64, nil) ->
        case Base.decode64(image_base64) do
          {:ok, image} ->
            {:ok, %{prompt: prompt, image: image, media_type: media_type}}

          :error ->
            {:error, Error.validation("image_base64 is not valid base64", source: __MODULE__)}
        end

      image_path = arg(args, :image_path, nil) ->
        with {:ok, resolved} <- Workspace.resolve_path(workspace, image_path, :read),
             {:ok, image} <- File.read(resolved.path) do
          {:ok, %{prompt: prompt, image: image, media_type: media_type, path: resolved.relative}}
        else
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> {:error, Error.from_reason(reason, source: __MODULE__)}
        end

      true ->
        {:error,
         Error.validation("vision input requires image_path, image_url, or image_base64",
           source: __MODULE__
         )}
    end
  end

  defp media_binary_input(%Workspace{} = workspace, args, kind) do
    path_key = :"#{kind}_path"
    base64_key = :"#{kind}_base64"
    media_type = arg(args, :media_type, arg(args, :document_type, "application/octet-stream"))

    cond do
      path = arg(args, path_key, nil) ->
        with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
             {:ok, binary} <- File.read(resolved.path) do
          if kind == :audio do
            {:ok, {:binary, binary, media_type}}
          else
            {:ok, binary}
          end
        else
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> {:error, Error.from_reason(reason, source: __MODULE__)}
        end

      encoded = arg(args, base64_key, nil) ->
        case Base.decode64(encoded) do
          {:ok, binary} ->
            if kind == :audio, do: {:ok, {:binary, binary, media_type}}, else: {:ok, binary}

          :error ->
            {:error, Error.validation("#{base64_key} is not valid base64", source: __MODULE__)}
        end

      true ->
        {:error,
         Error.validation("#{kind} input requires #{path_key} or #{base64_key}",
           source: __MODULE__
         )}
    end
  end

  defp persist_media_binary(workspace, kind, result, field, fallback_media_type) do
    binary = Map.get(result, field)
    media_type = Map.get(result, :media_type, fallback_media_type)

    artifact_ref =
      if is_binary(binary),
        do: persist_tool_artifact(workspace, kind, %{media_type: media_type, content: binary})

    result =
      if is_binary(binary) do
        result
        |> Map.put(:"#{field}_byte_size", byte_size(binary))
        |> Map.delete(field)
      else
        result
      end

    result
    |> Map.put(:artifact_ref, artifact_ref)
    |> Map.put_new(:media_type, media_type)
  end

  defp maybe_persist_text_artifact(workspace, kind, result, field) do
    content = Map.get(result, field)

    artifact_ref =
      if is_binary(content) and content != "", do: persist_tool_artifact(workspace, kind, result)

    Map.put(result, :artifact_ref, artifact_ref)
  end

  defp persist_tool_artifact(%Workspace{} = workspace, kind, payload) do
    content =
      cond do
        is_binary(Map.get(payload, :content)) -> Map.get(payload, :content)
        is_binary(Map.get(payload, :markdown)) -> Map.get(payload, :markdown)
        is_binary(Map.get(payload, :text)) -> Map.get(payload, :text)
        true -> Jason.encode!(model_output(payload))
      end

    sha256 = Patch.sha256(content)

    artifact = %{
      content: content,
      sha256: sha256,
      path: "#{kind}:#{sha256}",
      artifact_kind: kind,
      metadata: %{tool_artifact?: true, kind: kind, workspace_root: workspace.root}
    }

    case Persistence.put_artifact(workspace.persistence, artifact) do
      {:ok, ref} -> ref
      {:error, _error} -> nil
    end
  end

  defp browser_session(opts) do
    case Keyword.get(opts, :session) || Keyword.get(opts, :browser_session) do
      nil ->
        backend = Keyword.get(opts, :backend) || default_browser_backend()
        backend_opts = Keyword.get(opts, :backend_opts, opts)

        BrowserSession.start_link(
          backend: backend,
          backend_opts: backend_opts,
          inactivity_timeout_ms: Keyword.get(opts, :inactivity_timeout_ms, 120_000)
        )

      session ->
        {:ok, session}
    end
  end

  defp run_delegate(%Workspace{} = workspace, objective, args, opts) do
    agent_kind = arg(args, :agent_kind, "standard")
    profile = arg(args, :profile, "coding_read")
    toolsets = string_list_or_empty(arg(args, :toolsets, []))
    subagent_id = arg(args, :subagent_id, "subagent:#{System.unique_integer([:positive])}")

    base = %{
      status: :completed,
      subagent_id: subagent_id,
      agent_kind: agent_kind,
      objective: objective,
      profile: profile,
      toolsets: toolsets,
      summary: "Delegated task recorded for restricted child execution.",
      artifact_refs: [],
      intermediate_events_included?: false,
      workspace_root: workspace.root
    }

    case Keyword.get(opts, :runner) || Keyword.get(opts, :delegate_fun) do
      nil ->
        {:ok, base}

      runner when is_function(runner, 3) ->
        case runner.(objective, args, %{
               workspace: workspace,
               profile: profile,
               toolsets: toolsets
             }) do
          {:ok, result} -> {:ok, sanitize_delegate_result(Map.merge(base, normalize_map(result)))}
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> {:error, Error.from_reason(reason, source: __MODULE__)}
          result when is_map(result) -> {:ok, sanitize_delegate_result(Map.merge(base, result))}
        end

      runner ->
        {:error,
         Error.validation("delegate runner must be a function of arity 3",
           source: __MODULE__,
           details: %{runner: inspect(runner)}
         )}
    end
  end

  defp sanitize_delegate_result(result) do
    %{
      status: Map.get(result, :status, :completed),
      subagent_id: Map.get(result, :subagent_id),
      agent_kind: Map.get(result, :agent_kind, "standard"),
      objective: Map.get(result, :objective),
      profile: Map.get(result, :profile),
      toolsets: Map.get(result, :toolsets, []),
      summary: Map.get(result, :summary) || Map.get(result, :output) || "",
      artifact_refs: List.wrap(Map.get(result, :artifact_refs, [])),
      source_refs: List.wrap(Map.get(result, :source_refs, [])),
      intermediate_events_included?: false,
      workspace_root: Map.get(result, :workspace_root)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp record_delegate_events(nil, _args, _objective, _result), do: :ok

  defp record_delegate_events(%SQLiteStore{} = store, args, objective, result) do
    session_id = arg(args, :session_id, nil)
    run_id = arg(args, :run_id, nil)

    event =
      TerminalEvent.new!(:subagent,
        session_id: session_id,
        agent: :standard,
        phase: :delegation,
        status: :ok,
        title: "Subagent completed",
        detail: Map.get(result, :summary),
        data: %{
          run_id: run_id,
          subagent_id: Map.fetch!(result, :subagent_id),
          agent_kind: Map.get(result, :agent_kind),
          objective: objective,
          result: result
        }
      )

    case SQLite.record_terminal_event(store, event) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp record_delegate_events(_store, _args, _objective, _result), do: :ok

  defp default_browser_backend do
    if System.find_executable("agent-browser") do
      RunicAI.Browser.Backends.AgentBrowser
    else
      RunicAI.Browser.Backends.Fake
    end
  end

  defp maybe_put_arg(opts, key, args) do
    case arg(args, key, nil) do
      nil -> opts
      value -> Keyword.put(opts, key, value)
    end
  end

  defp datetime_iso(nil), do: nil
  defp datetime_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_iso(value), do: value

  defp normalize_profile_task(task) when is_atom(task), do: task
  defp normalize_profile_task("compile_project"), do: :compile_project
  defp normalize_profile_task("run_tests"), do: :run_tests
  defp normalize_profile_task("run_formatter"), do: :run_formatter
  defp normalize_profile_task("run_linter"), do: :run_linter
  defp normalize_profile_task(task), do: task

  defp mix_runtime_smoke(workspace, args, policy, opts) do
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
          policy,
          opts
        )

      _other ->
        project_command(workspace, args, policy, opts)
    end
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp put_tool_event_sink(opts, nil), do: opts

  defp put_tool_event_sink(opts, event_sink) when is_function(event_sink, 1),
    do: Keyword.put_new(opts, :event_sink, event_sink)

  defp put_tool_event_sink(opts, _event_sink), do: opts

  defp event_sink_opts(opts) do
    case Keyword.get(opts, :event_sink) do
      event_sink when is_function(event_sink, 1) -> [event_sink: event_sink]
      _other -> []
    end
  end

  defp arg(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
