defmodule RunicAI.RLM.Components.SourceDiscovery do
  @moduledoc """
  Workspace-bounded source discovery for generated RLM workflows.

  The component accepts explicit files, directories, or shallow glob patterns
  and returns source maps with stable provenance. It does not read file content;
  downstream split/materialization components decide how much text to load.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @default_max_files 64
  @default_max_depth 1
  @text_extensions MapSet.new([
                     ".csv",
                     ".ex",
                     ".exs",
                     ".heex",
                     ".json",
                     ".jsonl",
                     ".livemd",
                     ".md",
                     ".markdown",
                     ".txt"
                   ])

  @spec run(Workspace.t(), term(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(%Workspace{} = workspace, input, params \\ %{}) do
    params = opts_map(params)

    with {:ok, discovered} <- discover_all(workspace, paths(input, params), params) do
      max_files = integer_opt(params, :max_files, @default_max_files)
      selected = Enum.take(discovered, max_files)

      {:ok,
       %{
         sources: selected,
         count: length(selected),
         discovered_count: length(discovered),
         truncated?: length(discovered) > max_files,
         provenance: [%{component: inspect(__MODULE__), roots: paths(input, params)}]
       }}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp discover_all(workspace, paths, params) do
    paths
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {path, index}, {:ok, acc} ->
      case discover_path(workspace, path, index, params) do
        {:ok, sources} -> {:cont, {:ok, acc ++ sources}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, dedupe_sources(sources)}
      {:error, error} -> {:error, error}
    end
  end

  defp discover_path(workspace, source, index, params) when is_map(source) do
    path = get(source, :path, nil)
    id = get(source, :id, "source_#{index}")
    metadata = get(source, :metadata, %{})

    discover_path(workspace, path, id, metadata, params)
  end

  defp discover_path(workspace, path, index, params) when is_binary(path) do
    discover_path(workspace, path, "source_#{index}", %{}, params)
  end

  defp discover_path(_workspace, source, _index, _params) do
    {:error,
     Error.validation("source discovery expects paths or source maps",
       source: __MODULE__,
       details: %{source: source}
     )}
  end

  defp discover_path(_workspace, path, _id, _metadata, _params)
       when not is_binary(path) or path == "" do
    {:error,
     Error.validation("source discovery path must be a non-empty string",
       source: __MODULE__,
       details: %{path: path}
     )}
  end

  defp discover_path(workspace, path, id, metadata, params) do
    if glob?(path) do
      discover_glob(workspace, path, id, metadata, params)
    else
      with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read) do
        cond do
          File.regular?(resolved.path) ->
            {:ok, source_entry(resolved, id, metadata, :file)}

          File.dir?(resolved.path) ->
            discover_directory(workspace, resolved.relative, id, metadata, params)

          true ->
            {:error,
             Error.validation("source discovery path must be a file, directory, or glob",
               source: __MODULE__,
               details: %{path: path}
             )}
        end
      end
    end
  end

  defp discover_directory(workspace, relative, id, metadata, params) do
    max_depth = integer_opt(params, :max_depth, @default_max_depth)

    with {:ok, resolved} <- Workspace.resolve_path(workspace, relative, :read) do
      resolved.path
      |> walk_files(max_depth, include_hidden?(params))
      |> Enum.reduce_while({:ok, []}, fn absolute, {:ok, acc} ->
        with {:ok, relative_path} <- Workspace.relative_path(workspace, absolute),
             {:ok, file_resolved} <- Workspace.resolve_path(workspace, relative_path, :read) do
          if include_file?(relative_path, params) do
            entry_id = "#{id}:#{length(acc) + 1}"
            {:cont, {:ok, acc ++ source_entry(file_resolved, entry_id, metadata, :directory)}}
          else
            {:cont, {:ok, acc}}
          end
        else
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp discover_glob(workspace, pattern, id, metadata, params) do
    absolute_pattern = Path.join(workspace.root, pattern)

    absolute_pattern
    |> Path.wildcard(match_dot: include_hidden?(params))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn absolute, {:ok, acc} ->
      with {:ok, relative_path} <- Workspace.relative_path(workspace, absolute),
           {:ok, resolved} <- Workspace.resolve_path(workspace, relative_path, :read) do
        if include_file?(relative_path, params) do
          entry_id = "#{id}:#{length(acc) + 1}"
          {:cont, {:ok, acc ++ source_entry(resolved, entry_id, metadata, :glob)}}
        else
          {:cont, {:ok, acc}}
        end
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp walk_files(root, max_depth, include_hidden?) do
    root
    |> do_walk_files(0, max_depth, include_hidden?)
    |> Enum.sort()
  end

  defp do_walk_files(path, depth, max_depth, include_hidden?) do
    cond do
      File.regular?(path) ->
        [path]

      depth >= max_depth ->
        []

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.reject(&(not include_hidden? and String.starts_with?(&1, ".")))
        |> Enum.flat_map(fn name ->
          Path.join(path, name)
          |> do_walk_files(depth + 1, max_depth, include_hidden?)
        end)

      true ->
        []
    end
  end

  defp source_entry(resolved, id, metadata, discovery) do
    stat = File.stat!(resolved.path)
    extension = resolved.relative |> Path.extname() |> String.downcase()

    [
      %{
        id: id,
        path: resolved.relative,
        absolute_path: resolved.path,
        kind: :file,
        discovery: discovery,
        extension: extension,
        byte_size: stat.size,
        metadata: metadata,
        provenance: [%{path: resolved.relative, discovery: discovery}]
      }
    ]
  end

  defp dedupe_sources(sources) do
    Enum.uniq_by(sources, & &1.path)
  end

  defp include_file?(path, params) do
    extension = path |> Path.extname() |> String.downcase()
    extensions = extensions(params)

    text_file? = MapSet.member?(@text_extensions, extension)
    extension_allowed? = extensions == :all or MapSet.member?(extensions, extension)
    hidden_allowed? = include_hidden?(params) or not hidden_path?(path)

    text_file? and extension_allowed? and hidden_allowed?
  end

  defp hidden_path?(path), do: Enum.any?(Path.split(path), &String.starts_with?(&1, "."))

  defp extensions(params) do
    case get(params, :extensions, nil) || get(params, :extension_filters, nil) do
      nil ->
        :all

      [] ->
        :all

      values ->
        values
        |> List.wrap()
        |> Enum.map(&normalize_extension/1)
        |> MapSet.new()
    end
  end

  defp normalize_extension(value) do
    value = value |> to_string() |> String.downcase()
    if String.starts_with?(value, "."), do: value, else: "." <> value
  end

  defp paths(input, params) do
    explicit =
      get(params, :paths, nil) ||
        get(params, :sources, nil) ||
        get(params, :globs, nil) ||
        get(params, :glob, nil)

    case explicit do
      nil -> paths_from_input(input)
      values -> List.wrap(values)
    end
  end

  defp paths_from_input(%{sources: sources}) when is_list(sources), do: sources
  defp paths_from_input(%{"sources" => sources}) when is_list(sources), do: sources
  defp paths_from_input(%{paths: paths}) when is_list(paths), do: paths
  defp paths_from_input(%{"paths" => paths}) when is_list(paths), do: paths
  defp paths_from_input(values) when is_list(values), do: values
  defp paths_from_input(path) when is_binary(path), do: [path]
  defp paths_from_input(_input), do: []

  defp glob?(path), do: String.contains?(path, ["*", "?", "["])

  defp include_hidden?(params), do: truthy?(get(params, :include_hidden?, false))

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp integer_opt(opts, key, default) do
    case get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _other -> default
        end

      _other ->
        default
    end
  end

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
