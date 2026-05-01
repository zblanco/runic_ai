defmodule RunicAI.RLM.Components.SourceSplitter do
  @moduledoc """
  Generic source splitter for assistant-generated workflows.

  Sources are workspace-relative files or shallow directories. The output keeps
  slice text together with path and line-span provenance.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @default_max_bytes 8_000
  @default_max_sources 32
  @text_extensions MapSet.new([
                     ".md",
                     ".markdown",
                     ".txt",
                     ".jsonl",
                     ".json",
                     ".csv",
                     ".ex",
                     ".exs"
                   ])

  @spec run(Workspace.t(), [map() | String.t()], map() | keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(workspace, sources, opts \\ %{})

  def run(%Workspace{} = workspace, sources, opts) when is_list(sources) do
    opts = opts_map(opts)

    with {:ok, resolved_sources} <- resolve_sources(workspace, sources, opts) do
      slices =
        resolved_sources
        |> Enum.flat_map(&split_source(&1, opts))
        |> Enum.with_index(1)
        |> Enum.map(fn {slice, index} ->
          Map.put(slice, :id, "#{slice.source_id}:slice:#{index}")
        end)

      {:ok,
       %{
         slices: slices,
         count: length(slices),
         sources: Enum.map(resolved_sources, &Map.drop(&1, [:text])),
         strategy: strategy(opts)
       }}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  def run(%Workspace{} = workspace, %{sources: sources}, opts) when is_list(sources),
    do: run(workspace, sources, opts)

  def run(%Workspace{} = workspace, %{"sources" => sources}, opts) when is_list(sources),
    do: run(workspace, sources, opts)

  def run(_workspace, sources, _opts) do
    {:error,
     Error.validation("source splitter requires a list of sources",
       source: __MODULE__,
       details: %{sources: sources}
     )}
  end

  defp resolve_sources(workspace, sources, opts) do
    max_sources = integer_opt(opts, :max_sources, @default_max_sources)

    sources
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {source, index}, {:ok, acc} ->
      case resolve_source(workspace, source, index, opts) do
        {:ok, source_entries} ->
          next = acc ++ source_entries

          if length(next) > max_sources do
            {:halt,
             {:error,
              Error.validation("source splitter source budget exceeded",
                source: __MODULE__,
                details: %{max_sources: max_sources}
              )}}
          else
            {:cont, {:ok, next}}
          end

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp resolve_source(workspace, path, index, opts) when is_binary(path) do
    resolve_source(workspace, %{id: "source_#{index}", path: path}, index, opts)
  end

  defp resolve_source(workspace, source, index, opts) when is_map(source) do
    path = get(source, :path, nil)
    id = get(source, :id, "source_#{index}")

    with true <- (is_binary(path) and path != "") || {:error, :bad_path},
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read) do
      cond do
        File.dir?(resolved.path) ->
          resolve_directory(workspace, resolved.relative, id, opts)

        File.regular?(resolved.path) ->
          read_source_file(workspace, resolved.relative, id, source, opts)

        true ->
          {:error,
           Error.validation("source splitter path must be a file or directory",
             source: __MODULE__,
             details: %{path: path}
           )}
      end
    else
      {:error, :bad_path} ->
        {:error,
         Error.validation("source path must be a non-empty string",
           source: __MODULE__,
           details: %{source: source}
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp resolve_source(_workspace, source, _index, _opts) do
    {:error,
     Error.validation("source must be a path or source map",
       source: __MODULE__,
       details: %{source: source}
     )}
  end

  defp resolve_directory(workspace, relative, id, opts) do
    max_sources = integer_opt(opts, :max_directory_files, 16)

    with {:ok, resolved} <- Workspace.resolve_path(workspace, relative, :read),
         {:ok, names} <- File.ls(resolved.path) do
      names
      |> Enum.sort()
      |> Enum.map(&Path.join(relative, &1))
      |> Enum.filter(&text_file?(Path.extname(&1)))
      |> Enum.take(max_sources)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {path, index}, {:ok, acc} ->
        case read_source_file(
               workspace,
               path,
               "#{id}_#{index}",
               %{id: "#{id}_#{index}", path: path},
               opts
             ) do
          {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp read_source_file(workspace, relative, id, source, opts) do
    max_file_bytes = integer_opt(opts, :max_file_bytes, workspace.path_policy.max_file_bytes)

    with {:ok, resolved} <- Workspace.resolve_path(workspace, relative, :read),
         {:ok, stat} <- File.stat(resolved.path),
         :ok <- enforce_file_size(stat.size, max_file_bytes, relative),
         {:ok, text} <- File.read(resolved.path) do
      {:ok,
       [
         %{
           id: id,
           path: resolved.relative,
           absolute_path: resolved.path,
           text: text,
           byte_size: byte_size(text),
           metadata: Map.get(source, :metadata, Map.get(source, "metadata", %{}))
         }
       ]}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp enforce_file_size(size, max_file_bytes, _path) when size <= max_file_bytes,
    do: :ok

  defp enforce_file_size(size, max_file_bytes, path) do
    {:error,
     Error.validation("source file exceeds splitter max_file_bytes",
       source: __MODULE__,
       details: %{path: path, size: size, max_file_bytes: max_file_bytes}
     )}
  end

  defp split_source(source, opts) do
    strategy = strategy(opts)
    max_bytes = integer_opt(opts, :max_bytes, @default_max_bytes)

    units = units_for(source.text, strategy, max_bytes)

    units =
      if strategy == :markdown_heading do
        units
      else
        pack_units(units, max_bytes)
      end

    units
    |> Enum.with_index(1)
    |> Enum.map(fn {unit, index} ->
      %{
        source_id: source.id,
        path: source.path,
        index: index,
        text: unit.text,
        start_line: unit.start_line,
        end_line: unit.end_line,
        byte_size: byte_size(unit.text),
        char_count: String.length(unit.text),
        provenance: [
          %{source_id: source.id, path: source.path, line_span: [unit.start_line, unit.end_line]}
        ]
      }
    end)
  end

  defp units_for(text, :lines, _max_bytes) do
    text
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, line_number} ->
      %{text: line, start_line: line_number, end_line: line_number}
    end)
  end

  defp units_for(text, :markdown_heading, _max_bytes) do
    lines = String.split(text, "\n", trim: false)

    lines
    |> Enum.with_index(1)
    |> Enum.chunk_while(
      nil,
      fn {line, line_number}, acc ->
        heading? = String.match?(line, ~r/^\#{1,6}\s+/)

        cond do
          is_nil(acc) ->
            {:cont, %{lines: [line], start_line: line_number, end_line: line_number}}

          heading? ->
            {:cont, acc, %{lines: [line], start_line: line_number, end_line: line_number}}

          true ->
            {:cont, %{acc | lines: acc.lines ++ [line], end_line: line_number}}
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, []}
      end
    )
    |> Enum.map(&Map.update!(&1, :lines, fn lines -> Enum.join(lines, "\n") end))
    |> Enum.map(fn unit ->
      %{text: unit.lines, start_line: unit.start_line, end_line: unit.end_line}
    end)
  end

  defp units_for(text, :paragraph, _max_bytes) do
    text
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.chunk_while(
      nil,
      fn {line, line_number}, acc ->
        blank? = String.trim(line) == ""

        cond do
          is_nil(acc) and blank? ->
            {:cont, %{lines: [line], start_line: line_number, end_line: line_number}}

          is_nil(acc) ->
            {:cont, %{lines: [line], start_line: line_number, end_line: line_number}}

          blank? ->
            {:cont, %{acc | lines: acc.lines ++ [line], end_line: line_number}, nil}

          true ->
            {:cont, %{acc | lines: acc.lines ++ [line], end_line: line_number}}
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, []}
      end
    )
    |> Enum.map(fn unit ->
      %{text: Enum.join(unit.lines, "\n"), start_line: unit.start_line, end_line: unit.end_line}
    end)
  end

  defp units_for(text, :bytes, max_bytes), do: byte_units(text, max_bytes)
  defp units_for(text, _strategy, max_bytes), do: units_for(text, :paragraph, max_bytes)

  defp byte_units(text, max_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce({[], "", 1, 1}, fn grapheme, {units, current, start_line, current_line} ->
      next = current <> grapheme
      next_line = current_line + if(grapheme == "\n", do: 1, else: 0)

      if byte_size(next) > max_bytes and current != "" do
        unit = %{text: current, start_line: start_line, end_line: current_line}
        {[unit | units], grapheme, next_line, next_line}
      else
        {units, next, start_line, next_line}
      end
    end)
    |> case do
      {units, "", _start_line, _current_line} ->
        units

      {units, current, start_line, current_line} ->
        [%{text: current, start_line: start_line, end_line: current_line} | units]
    end
    |> Enum.reverse()
  end

  defp pack_units(units, max_bytes) do
    units
    |> Enum.reduce([], fn unit, acc ->
      case acc do
        [] ->
          [unit]

        [current | rest] ->
          candidate_text = current.text <> "\n" <> unit.text

          if byte_size(candidate_text) <= max_bytes do
            [%{current | text: candidate_text, end_line: unit.end_line} | rest]
          else
            [unit, current | rest]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp strategy(opts) do
    case get(opts, :strategy, :paragraph) do
      value when value in [:paragraph, :lines, :bytes, :markdown_heading] -> value
      "paragraph" -> :paragraph
      "lines" -> :lines
      "bytes" -> :bytes
      "markdown_heading" -> :markdown_heading
      "markdown-heading" -> :markdown_heading
      _other -> :paragraph
    end
  end

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

  defp text_file?(extension), do: MapSet.member?(@text_extensions, String.downcase(extension))

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
