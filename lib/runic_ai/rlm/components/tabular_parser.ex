defmodule RunicAI.RLM.Components.TabularParser do
  @moduledoc """
  Generic CSV, JSONL, and Markdown-table ingestion for RLM workflows.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @spec run(term(), map() | keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, params \\ %{}, opts \\ []) when is_list(opts) do
    params = opts_map(params)
    workspace = Keyword.get(opts, :workspace)

    with {:ok, documents} <- documents(input, workspace),
         {:ok, parsed} <- parse_documents(documents, params) do
      records = Enum.flat_map(parsed, & &1.records)

      {:ok,
       %{
         records: records,
         count: length(records),
         formats: parsed |> Enum.map(& &1.format) |> Enum.uniq(),
         columns: parsed |> Enum.flat_map(& &1.columns) |> Enum.uniq(),
         sources: Enum.map(documents, &Map.drop(&1, [:text]))
       }}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp parse_documents(documents, params) do
    documents
    |> Enum.reduce_while({:ok, []}, fn document, {:ok, acc} ->
      case parse_document(document, params) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp parse_document(document, params) do
    format = format(document, params)

    case format do
      :csv -> parse_csv(document)
      :jsonl -> parse_jsonl(document)
      :markdown_table -> parse_markdown_table(document)
      :json -> parse_json(document)
      :unknown -> {:ok, %{format: :unknown, columns: [], records: []}}
    end
  end

  defp parse_jsonl(document) do
    records =
      document.text
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {line, row_number}, {:ok, acc} ->
        case Jason.decode(line) do
          {:ok, value} when is_map(value) ->
            {:cont, {:ok, acc ++ [record(document, row_number, value)]}}

          {:ok, value} ->
            {:cont, {:ok, acc ++ [record(document, row_number, %{"value" => value})]}}

          {:error, reason} ->
            {:halt,
             {:error,
              Error.validation("JSONL record could not be decoded",
                source: __MODULE__,
                details: %{
                  path: document.path,
                  row: row_number,
                  reason: Exception.message(reason)
                }
              )}}
        end
      end)

    with {:ok, records} <- records do
      {:ok, %{format: :jsonl, columns: columns(records), records: records}}
    end
  end

  defp parse_json(document) do
    case Jason.decode(document.text) do
      {:ok, values} when is_list(values) ->
        records =
          values
          |> Enum.with_index(1)
          |> Enum.map(fn {value, row_number} ->
            data = if is_map(value), do: value, else: %{"value" => value}
            record(document, row_number, data)
          end)

        {:ok, %{format: :json, columns: columns(records), records: records}}

      {:ok, value} when is_map(value) ->
        records = [record(document, 1, value)]
        {:ok, %{format: :json, columns: columns(records), records: records}}

      {:ok, value} ->
        records = [record(document, 1, %{"value" => value})]
        {:ok, %{format: :json, columns: ["value"], records: records}}

      {:error, reason} ->
        {:error,
         Error.validation("JSON source could not be decoded",
           source: __MODULE__,
           details: %{path: document.path, reason: Exception.message(reason)}
         )}
    end
  end

  defp parse_csv(document) do
    rows =
      document.text
      |> String.split("\n", trim: true)
      |> Enum.map(&parse_csv_row/1)

    case rows do
      [] ->
        {:ok, %{format: :csv, columns: [], records: []}}

      [headers | data_rows] ->
        headers = Enum.map(headers, &String.trim/1)

        records =
          data_rows
          |> Enum.with_index(2)
          |> Enum.map(fn {row, row_number} ->
            data =
              headers
              |> Enum.zip(row ++ List.duplicate("", max(length(headers) - length(row), 0)))
              |> Map.new(fn {key, value} -> {key, value} end)

            record(document, row_number, data)
          end)

        {:ok, %{format: :csv, columns: headers, records: records}}
    end
  end

  defp parse_markdown_table(document) do
    rows =
      document.text
      |> String.split("\n", trim: true)
      |> Enum.filter(
        &(String.starts_with?(String.trim(&1), "|") and String.ends_with?(String.trim(&1), "|"))
      )
      |> Enum.reject(&markdown_divider?/1)
      |> Enum.map(&parse_markdown_row/1)

    case rows do
      [] ->
        {:ok, %{format: :markdown_table, columns: [], records: []}}

      [headers | data_rows] ->
        records =
          data_rows
          |> Enum.with_index(2)
          |> Enum.map(fn {row, row_number} ->
            data =
              headers
              |> Enum.zip(row ++ List.duplicate("", max(length(headers) - length(row), 0)))
              |> Map.new(fn {key, value} -> {key, value} end)

            record(document, row_number, data)
          end)

        {:ok, %{format: :markdown_table, columns: headers, records: records}}
    end
  end

  defp documents(%{sources: sources}, workspace), do: read_sources(sources, workspace)
  defp documents(%{"sources" => sources}, workspace), do: read_sources(sources, workspace)

  defp documents(%{slices: slices}, _workspace) when is_list(slices),
    do: from_text_entries(slices)

  defp documents(%{"slices" => slices}, _workspace) when is_list(slices),
    do: from_text_entries(slices)

  defp documents(%{text: text} = input, _workspace) when is_binary(text),
    do: {:ok, [document(input, text)]}

  defp documents(%{"text" => text} = input, _workspace) when is_binary(text),
    do: {:ok, [document(input, text)]}

  defp documents(text, _workspace) when is_binary(text),
    do: {:ok, [%{id: "input", path: nil, text: text}]}

  defp documents(values, workspace) when is_list(values), do: read_sources(values, workspace)

  defp documents(input, _workspace) do
    {:error,
     Error.validation("tabular parser expected sources, slices, text, or paths",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  defp read_sources(sources, workspace) when is_list(sources) do
    sources
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {source, index}, {:ok, acc} ->
      case read_source(source, workspace, index) do
        {:ok, document} -> {:cont, {:ok, acc ++ [document]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp read_source(%{text: text} = source, _workspace, _index) when is_binary(text),
    do: {:ok, document(source, text)}

  defp read_source(%{"text" => text} = source, _workspace, _index) when is_binary(text),
    do: {:ok, document(source, text)}

  defp read_source(path, workspace, index) when is_binary(path) do
    read_source(%{id: "source_#{index}", path: path}, workspace, index)
  end

  defp read_source(source, %Workspace{} = workspace, index) when is_map(source) do
    path = get(source, :path, nil)

    with true <- is_binary(path) and path != "",
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         {:ok, text} <- File.read(resolved.path) do
      {:ok,
       %{
         id: get(source, :id, "source_#{index}"),
         path: resolved.relative,
         text: text,
         provenance: get(source, :provenance, [%{path: resolved.relative}])
       }}
    else
      false ->
        {:error,
         Error.validation("tabular source path must be a non-empty string",
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
     Error.validation("tabular source must include text or a workspace-readable path",
       source: __MODULE__,
       details: %{source: source}
     )}
  end

  defp from_text_entries(entries) do
    {:ok,
     entries
     |> Enum.with_index(1)
     |> Enum.map(fn {entry, index} ->
       document(entry, get(entry, :text, ""), index)
     end)}
  end

  defp document(source, text, index \\ 1) do
    %{
      id: get(source, :id, "source_#{index}"),
      path: get(source, :path, nil),
      text: text,
      provenance: get(source, :provenance, [])
    }
  end

  defp record(document, row_number, data) do
    %{
      id: "#{document.id}:row:#{row_number}",
      row_number: row_number,
      source_path: document.path,
      data: data,
      provenance: [%{path: document.path, row: row_number}]
    }
  end

  defp columns(records) do
    records
    |> Enum.flat_map(fn record -> Map.keys(record.data) end)
    |> Enum.uniq()
  end

  defp format(document, params) do
    case get(params, :format, nil) do
      value when value in [:csv, :jsonl, :json, :markdown_table] -> value
      "csv" -> :csv
      "jsonl" -> :jsonl
      "json" -> :json
      "markdown_table" -> :markdown_table
      "markdown-table" -> :markdown_table
      _other -> format_from_path(document.path, document.text)
    end
  end

  defp format_from_path(path, text) do
    case path && String.downcase(Path.extname(path)) do
      ".csv" -> :csv
      ".jsonl" -> :jsonl
      ".json" -> :json
      _other -> if String.contains?(text, "|---"), do: :markdown_table, else: :unknown
    end
  end

  defp parse_csv_row(line), do: parse_csv_row(String.graphemes(line), "", [], false)

  defp parse_csv_row([], field, acc, _quoted?), do: Enum.reverse([field | acc])
  defp parse_csv_row(["\"" | rest], field, acc, false), do: parse_csv_row(rest, field, acc, true)
  defp parse_csv_row(["\"" | rest], field, acc, true), do: parse_csv_row(rest, field, acc, false)

  defp parse_csv_row(["," | rest], field, acc, false),
    do: parse_csv_row(rest, "", [field | acc], false)

  defp parse_csv_row([char | rest], field, acc, quoted?),
    do: parse_csv_row(rest, field <> char, acc, quoted?)

  defp parse_markdown_row(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp markdown_divider?(line), do: String.match?(line, ~r/^\s*\|?[\s:-]+\|[\s|:-]*$/)

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
