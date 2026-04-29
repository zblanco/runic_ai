defmodule RunicAI.Coding.RLM.StructuralSplitter do
  @moduledoc """
  Structural slice helpers for codebase RLM sources.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.Slice

  @spec file(EnvironmentRef.t(), String.t(), keyword()) :: {:ok, Slice.t()} | {:error, Error.t()}
  def file(%EnvironmentRef{} = ref, content, opts \\ []) when is_binary(content) do
    Slice.new(ref, 0, String.length(content),
      label: Keyword.get(opts, :label, ref.label),
      metadata: Map.merge(%{slice_mode: :file}, Keyword.get(opts, :metadata, %{}))
    )
  end

  @spec line_window(EnvironmentRef.t(), String.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, Slice.t()} | {:error, Error.t()}
  def line_window(%EnvironmentRef{} = ref, content, start_line, end_line, opts \\ [])
      when is_binary(content) and is_integer(start_line) and is_integer(end_line) do
    with :ok <- validate_line_window(start_line, end_line),
         {:ok, offset, length} <- line_offsets(content, start_line, end_line) do
      Slice.new(ref, offset, length,
        label: Keyword.get(opts, :label, "#{ref.source_id}:L#{start_line}-L#{end_line}"),
        metadata:
          Map.merge(
            %{slice_mode: :line_window, start_line: start_line, end_line: end_line},
            Keyword.get(opts, :metadata, %{})
          )
      )
    end
  end

  @spec search_hits(EnvironmentRef.t(), String.t(), String.t(), keyword()) ::
          {:ok, [Slice.t()]} | {:error, Error.t()}
  def search_hits(%EnvironmentRef{} = ref, content, query, opts \\ [])
      when is_binary(content) and is_binary(query) and is_list(opts) do
    context = Keyword.get(opts, :context, 80)

    with :ok <- validate_query(query),
         :ok <- validate_context(context) do
      query_length = String.length(query)

      slices =
        content
        |> match_offsets(query)
        |> Enum.with_index()
        |> Enum.map(fn {match_offset, index} ->
          offset = max(match_offset - context, 0)
          end_offset = min(match_offset + query_length + context, String.length(content))

          Slice.new!(ref, offset, end_offset - offset,
            index: index,
            label: "#{ref.source_id}:search:#{index}",
            metadata: %{slice_mode: :search_hit, query: query, match_offset: match_offset}
          )
        end)

      {:ok, slices}
    end
  end

  @spec diff_hunks(EnvironmentRef.t(), String.t(), keyword()) ::
          {:ok, [Slice.t()]} | {:error, Error.t()}
  def diff_hunks(%EnvironmentRef{} = ref, diff_text, opts \\ [])
      when is_binary(diff_text) and is_list(opts) do
    slices_for_sections(ref, diff_text, ~r/^@@ /m, :diff_hunk, opts)
  end

  @spec command_log_sections(EnvironmentRef.t(), String.t(), keyword()) ::
          {:ok, [Slice.t()]} | {:error, Error.t()}
  def command_log_sections(%EnvironmentRef{} = ref, log_text, opts \\ [])
      when is_binary(log_text) and is_list(opts) do
    slices_for_sections(
      ref,
      log_text,
      ~r/^\S.*(?:error|fail|warning|test)/im,
      :command_log_section,
      opts
    )
  end

  defp slices_for_sections(ref, content, regex, mode, opts) do
    offsets =
      regex
      |> Regex.scan(content, return: :index)
      |> Enum.map(fn [{offset, _length} | _] -> offset end)
      |> case do
        [] -> [0]
        offsets -> offsets
      end

    slices =
      offsets
      |> Enum.with_index()
      |> Enum.map(fn {offset, index} ->
        next_offset = Enum.at(offsets, index + 1, String.length(content))
        length = max(next_offset - offset, 0)

        Slice.new!(ref, offset, length,
          index: index,
          label: "#{ref.source_id}:#{mode}:#{index}",
          metadata: Map.merge(%{slice_mode: mode}, Keyword.get(opts, :metadata, %{}))
        )
      end)

    {:ok, slices}
  end

  defp validate_line_window(start_line, end_line)
       when start_line > 0 and end_line >= start_line,
       do: :ok

  defp validate_line_window(start_line, end_line) do
    {:error,
     Error.validation("line window requires positive start_line and end_line >= start_line",
       source: __MODULE__,
       details: %{start_line: start_line, end_line: end_line}
     )}
  end

  defp validate_query(query) when query != "", do: :ok

  defp validate_query(query) do
    {:error,
     Error.validation("search hit query must be non-empty",
       source: __MODULE__,
       details: %{query: query}
     )}
  end

  defp validate_context(context) when is_integer(context) and context >= 0, do: :ok

  defp validate_context(context) do
    {:error,
     Error.validation("search hit context must be non-negative",
       source: __MODULE__,
       details: %{context: context}
     )}
  end

  defp line_offsets(content, start_line, end_line) do
    lines = String.split(content, "\n", trim: false)

    if start_line > length(lines) do
      {:error,
       Error.validation("line window starts after end of content",
         source: __MODULE__,
         details: %{start_line: start_line, line_count: length(lines)}
       )}
    else
      prefix =
        lines
        |> Enum.take(start_line - 1)
        |> Enum.join("\n")

      selected =
        lines
        |> Enum.slice((start_line - 1)..(end_line - 1))
        |> Enum.join("\n")

      offset = if prefix == "", do: 0, else: String.length(prefix) + 1
      {:ok, offset, String.length(selected)}
    end
  end

  defp match_offsets(content, query) do
    query_length = String.length(query)
    max_offset = String.length(content) - query_length

    if max_offset < 0 do
      []
    else
      0..max_offset
      |> Enum.filter(&(String.slice(content, &1, query_length) == query))
    end
  end
end
