defmodule RunicAI.RLM.Components.DocumentCompare do
  @moduledoc """
  Lightweight multi-document comparison for generated RLM workflows.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @spec run(term(), map() | keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, params \\ %{}, opts \\ []) when is_list(opts) do
    workspace = Keyword.get(opts, :workspace)

    with {:ok, documents} <- documents(input, workspace) do
      pairs = pair_documents(documents, opts_map(params))

      comparisons =
        Enum.map(pairs, fn {left, right} ->
          compare_pair(left, right)
        end)

      {:ok,
       %{
         comparisons: comparisons,
         count: length(comparisons),
         sources: Enum.map(documents, &Map.drop(&1, [:text]))
       }}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp compare_pair(left, right) do
    left_lines = lines(left.text)
    right_lines = lines(right.text)
    left_set = MapSet.new(left_lines)
    right_set = MapSet.new(right_lines)

    added = right_lines |> Enum.reject(&MapSet.member?(left_set, &1)) |> Enum.take(40)
    removed = left_lines |> Enum.reject(&MapSet.member?(right_set, &1)) |> Enum.take(40)

    %{
      left: left.path,
      right: right.path,
      added_count: length(right_set |> MapSet.difference(left_set) |> MapSet.to_list()),
      removed_count: length(left_set |> MapSet.difference(right_set) |> MapSet.to_list()),
      added: added,
      removed: removed,
      change_candidates: change_candidates(left_lines, right_lines),
      provenance: [%{left: left.path, right: right.path}]
    }
  end

  defp change_candidates(left_lines, right_lines) do
    left_lines
    |> Enum.zip(right_lines)
    |> Enum.with_index(1)
    |> Enum.reject(fn {{left, right}, _line} -> left == right end)
    |> Enum.take(40)
    |> Enum.map(fn {{left, right}, line} -> %{line: line, before: left, after: right} end)
  end

  defp pair_documents([left, right | _rest], _params), do: [{left, right}]
  defp pair_documents(_documents, _params), do: []

  defp documents(%{sources: sources}, workspace), do: read_sources(sources, workspace)
  defp documents(%{"sources" => sources}, workspace), do: read_sources(sources, workspace)

  defp documents(%{slices: slices}, _workspace) when is_list(slices),
    do: from_text_entries(slices)

  defp documents(%{"slices" => slices}, _workspace) when is_list(slices),
    do: from_text_entries(slices)

  defp documents(values, workspace) when is_list(values), do: read_sources(values, workspace)

  defp documents(input, _workspace) do
    {:error,
     Error.validation("document compare expected sources or slices",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  defp read_sources(sources, workspace) do
    sources
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {source, index}, {:ok, acc} ->
      case read_source(source, workspace, index) do
        {:ok, document} -> {:cont, {:ok, acc ++ [document]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp read_source(%{text: text} = source, _workspace, index) when is_binary(text),
    do: {:ok, document(source, text, index)}

  defp read_source(%{"text" => text} = source, _workspace, index) when is_binary(text),
    do: {:ok, document(source, text, index)}

  defp read_source(path, workspace, index) when is_binary(path),
    do: read_source(%{id: "source_#{index}", path: path}, workspace, index)

  defp read_source(source, %Workspace{} = workspace, index) when is_map(source) do
    path = get(source, :path, nil)

    with true <- is_binary(path) and path != "",
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         {:ok, text} <- File.read(resolved.path) do
      {:ok, document(Map.put(source, :path, resolved.relative), text, index)}
    else
      false ->
        {:error,
         Error.validation("document source path must be a non-empty string",
           source: __MODULE__,
           details: %{source: source}
         )}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp read_source(source, _workspace, _index) do
    {:error,
     Error.validation("document source must include text or a workspace-readable path",
       source: __MODULE__,
       details: %{source: source}
     )}
  end

  defp from_text_entries(entries) do
    {:ok,
     entries
     |> Enum.with_index(1)
     |> Enum.map(fn {entry, index} -> document(entry, get(entry, :text, ""), index) end)}
  end

  defp document(source, text, index) do
    %{
      id: get(source, :id, "source_#{index}"),
      path: get(source, :path, "source_#{index}"),
      text: text,
      provenance: get(source, :provenance, [])
    }
  end

  defp lines(text),
    do:
      text
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
