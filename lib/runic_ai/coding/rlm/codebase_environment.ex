defmodule RunicAI.Coding.RLM.CodebaseEnvironment do
  @moduledoc """
  Codebase-specific RLM environment backed by `RunicAI.Coding.Workspace`.
  """

  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM
  alias RunicAI.RLM.Environments.InMemory
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.MaterializedArtifact
  alias RunicAI.RLM.Slice
  alias RunicAI.Coding.RLM.SourceIndex
  alias RunicAI.Coding.RLM.StructuralSplitter

  @default_file_limit 500

  @enforce_keys [:workspace, :environment, :source_index, :metadata]
  defstruct [:workspace, :environment, :source_index, metadata: %{}]

  @type t :: %__MODULE__{
          workspace: Workspace.t(),
          environment: term(),
          source_index: SourceIndex.t(),
          metadata: map()
        }

  @spec new(Workspace.t() | keyword() | map() | Path.t(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(workspace_input, opts \\ []) when is_list(opts) do
    with {:ok, workspace} <- Workspace.from_input(workspace_input),
         {:ok, environment} <- init_environment(opts),
         source_index = SourceIndex.new(metadata: %{workspace_root: workspace.root}) do
      env = %__MODULE__{
        workspace: workspace,
        environment: environment,
        source_index: source_index,
        metadata: Keyword.get(opts, :metadata, %{})
      }

      if Keyword.get(opts, :index?, false) do
        index_workspace(env, opts)
      else
        {:ok, env}
      end
    end
  end

  @spec new!(Workspace.t() | keyword() | map() | Path.t(), keyword()) :: t()
  def new!(workspace_input, opts \\ []) do
    case new(workspace_input, opts) do
      {:ok, env} -> env
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec index_workspace(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def index_workspace(%__MODULE__{} = env, opts \\ []) when is_list(opts) do
    with {:ok, env} <- register_manifest(env),
         {:ok, env} <- register_instructions(env),
         {:ok, files} <- files(env, opts) do
      Enum.reduce_while(files, {:ok, env}, fn file, {:ok, env} ->
        case register_file(env, file.path, tags: tags_for(file.path)) do
          {:ok, env, _ref} -> {:cont, {:ok, env}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  @spec register_file(t(), Path.t(), keyword()) ::
          {:ok, t(), EnvironmentRef.t()} | {:error, Error.t()}
  def register_file(%__MODULE__{} = env, path, opts \\ []) when is_binary(path) do
    with {:ok, resolved} <- Workspace.resolve_path(env.workspace, path, :read),
         {:ok, content} <- File.read(resolved.path),
         :ok <- validate_text_file(resolved.relative, content),
         metadata = file_metadata(resolved.relative, content, opts),
         {:ok, ref, rlm_env} <-
           RLM.put_source(env.environment, content,
             id: "file:#{resolved.relative}",
             label: resolved.relative,
             kind: :code,
             metadata: metadata
           ),
         {:ok, source_index} <-
           SourceIndex.put(env.source_index, ref,
             id: ref.source_id,
             path: resolved.relative,
             kind: metadata.kind,
             metadata: metadata
           ) do
      {:ok, %{env | environment: rlm_env, source_index: source_index}, ref}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      :skip_binary ->
        {:ok, env, nil}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "failed to register codebase file"
         )}
    end
  end

  @spec register_text(t(), String.t(), keyword()) ::
          {:ok, t(), EnvironmentRef.t()} | {:error, Error.t()}
  def register_text(%__MODULE__{} = env, content, opts \\ [])
      when is_binary(content) and is_list(opts) do
    id = Keyword.get(opts, :id) || "artifact:#{System.unique_integer([:positive])}"
    metadata = Keyword.get(opts, :metadata, %{})
    kind = Keyword.get(opts, :kind, :artifact)

    with {:ok, ref, rlm_env} <-
           RLM.put_source(env.environment, content,
             id: id,
             label: Keyword.get(opts, :label),
             kind: :artifact,
             metadata: Map.merge(metadata, %{kind: kind, size: String.length(content)})
           ),
         {:ok, source_index} <-
           SourceIndex.put(env.source_index, ref,
             id: ref.source_id,
             kind: kind,
             metadata: Map.merge(metadata, %{kind: kind, size: String.length(content)})
           ) do
      {:ok, %{env | environment: rlm_env, source_index: source_index}, ref}
    end
  end

  @spec materialize(t(), String.t() | EnvironmentRef.t() | Slice.t(), keyword()) ::
          {:ok, MaterializedArtifact.t()} | {:error, Error.t()}
  def materialize(env, id_or_ref_or_slice, opts \\ [])

  def materialize(%__MODULE__{} = env, %EnvironmentRef{} = ref, opts) do
    RLM.materialize(env.environment, ref, opts)
  end

  def materialize(%__MODULE__{} = env, %Slice{} = slice, opts) do
    RLM.materialize(env.environment, slice, opts)
  end

  def materialize(%__MODULE__{} = env, id_or_path, opts) when is_binary(id_or_path) do
    with {:ok, entry} <- SourceIndex.fetch(env.source_index, id_or_path) do
      materialize(env, entry.ref, opts)
    end
  end

  @spec slice(t(), String.t(), atom(), keyword()) ::
          {:ok, Slice.t() | [Slice.t()]} | {:error, Error.t()}
  def slice(%__MODULE__{} = env, id_or_path, mode, opts \\ [])
      when is_binary(id_or_path) and is_atom(mode) and is_list(opts) do
    with {:ok, entry} <- SourceIndex.fetch(env.source_index, id_or_path),
         {:ok, artifact} <- materialize(env, entry.ref) do
      do_slice(entry.ref, artifact.content, mode, opts)
    end
  end

  @spec source_summaries(t(), non_neg_integer()) :: [map()]
  def source_summaries(%__MODULE__{} = env, limit \\ 100),
    do: SourceIndex.summaries(env.source_index, limit)

  defp do_slice(ref, content, :file, opts), do: StructuralSplitter.file(ref, content, opts)

  defp do_slice(ref, content, :line_window, opts) do
    StructuralSplitter.line_window(
      ref,
      content,
      Keyword.fetch!(opts, :start_line),
      Keyword.fetch!(opts, :end_line),
      opts
    )
  end

  defp do_slice(ref, content, :search_hit, opts) do
    StructuralSplitter.search_hits(ref, content, Keyword.fetch!(opts, :query), opts)
  end

  defp do_slice(ref, content, :diff_hunk, opts),
    do: StructuralSplitter.diff_hunks(ref, content, opts)

  defp do_slice(ref, content, :command_log_section, opts),
    do: StructuralSplitter.command_log_sections(ref, content, opts)

  defp do_slice(_ref, _content, mode, _opts) do
    {:error,
     Error.validation("unsupported codebase structural slice mode",
       source: __MODULE__,
       details: %{mode: mode}
     )}
  end

  defp register_manifest(%__MODULE__{} = env) do
    case Tools.list_dir(env.workspace, %{path: ".", limit: 200}) do
      {:ok, manifest} ->
        register_text(env, Jason.encode!(manifest),
          id: "repo:manifest",
          label: "Repository manifest",
          kind: :repo_manifest,
          metadata: %{kind: :repo_manifest, tags: [:manifest]}
        )
        |> case do
          {:ok, env, _ref} -> {:ok, env}
          error -> error
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp register_instructions(%__MODULE__{} = env) do
    path = Path.join(env.workspace.root, "AGENTS.md")

    case File.read(path) do
      {:ok, content} ->
        register_text(env, content,
          id: "repo:instructions",
          label: "AGENTS.md",
          kind: :instructions,
          metadata: %{kind: :instructions, path: "AGENTS.md", tags: [:instructions]}
        )
        |> case do
          {:ok, env, _ref} -> {:ok, env}
          error -> error
        end

      {:error, _reason} ->
        {:ok, env}
    end
  end

  defp files(%__MODULE__{} = env, opts) do
    limit = Keyword.get(opts, :file_limit, @default_file_limit)
    include_hidden? = Keyword.get(opts, :include_hidden, false)

    case Tools.find_files(env.workspace, %{
           path: ".",
           include_hidden: include_hidden?,
           limit: limit
         }) do
      {:ok, %{files: files}} ->
        {:ok, Enum.reject(files, &ignored_file?/1)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ignored_file?(%{path: path}) do
    String.starts_with?(path, "_build/") or String.starts_with?(path, "deps/") or
      String.starts_with?(path, "tmp/")
  end

  defp validate_text_file(_path, content) when is_binary(content) do
    if String.valid?(content), do: :ok, else: :skip_binary
  end

  defp file_metadata(relative, content, opts) do
    %{
      kind: file_kind(relative),
      path: relative,
      language: language(relative),
      size: byte_size(content),
      checksum: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      tags: Keyword.get(opts, :tags, tags_for(relative))
    }
  end

  defp file_kind(path) do
    cond do
      String.starts_with?(path, "test/") -> :test_file
      Path.extname(path) in [".ex", ".exs", ".heex", ".eex"] -> :source_file
      true -> :file
    end
  end

  defp language(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".heex" -> :elixir
      ".eex" -> :elixir
      ".md" -> :markdown
      ".json" -> :json
      ".yml" -> :yaml
      ".yaml" -> :yaml
      _ -> :text
    end
  end

  defp tags_for(path) do
    []
    |> maybe_tag(String.starts_with?(path, "test/"), :test)
    |> maybe_tag(String.starts_with?(path, "lib/"), :source)
    |> maybe_tag(Path.basename(path) == "mix.exs", :manifest)
  end

  defp maybe_tag(tags, true, tag), do: [tag | tags]
  defp maybe_tag(tags, false, _tag), do: tags

  defp init_environment(opts) do
    case Keyword.get(opts, :environment) do
      nil -> InMemory.init(metadata: %{kind: :coding_rlm})
      environment -> {:ok, environment}
    end
  end
end
