defmodule RunicAI.Terminal.MarkdownBlocks do
  @moduledoc """
  Conservative Markdown block extraction for terminal presentation.

  This is not a full Markdown parser. ExRatatui's Markdown widget handles rich
  Markdown rendering. This module only identifies block boundaries that matter
  to RunicAI presentation, especially fenced code and Mermaid blocks that need
  special handling.
  """

  alias RunicAI.Terminal.RenderedContent

  @fence_re ~r/^\s*```\s*([A-Za-z0-9_+.#-]*)\s*$/
  @table_re ~r/^\s*\|.+\|\s*$/

  @spec parse(String.t(), keyword()) :: [RenderedContent.t()]
  def parse(text, opts \\ []) when is_binary(text) do
    source_id = Keyword.get(opts, :source_id, "markdown")

    text
    |> String.split("\n", trim: false)
    |> collect(source_id, 1, [], [])
    |> Enum.reverse()
    |> Enum.reject(&(&1.text == ""))
  end

  @spec contains_mermaid?(String.t()) :: boolean()
  def contains_mermaid?(text) when is_binary(text) do
    text
    |> parse()
    |> Enum.any?(&(&1.kind == :mermaid))
  end

  @spec markdown?(String.t()) :: boolean()
  def markdown?(text) when is_binary(text) do
    String.contains?(text, ["# ", "## ", "- ", "* ", "```", "|", "**", "__", "> "])
  end

  @spec escape_raw_html(String.t()) :: String.t()
  def escape_raw_html(text) when is_binary(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map_reduce(false, fn line, in_fence? ->
      case Regex.run(@fence_re, line) do
        [_, _language] ->
          {line, not in_fence?}

        _other when in_fence? ->
          {line, in_fence?}

        _other ->
          {escape_html_line(line), in_fence?}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  @spec mermaid_sources(String.t(), keyword()) :: [%{id: String.t(), source: String.t()}]
  def mermaid_sources(text, opts \\ []) when is_binary(text) do
    text
    |> parse(opts)
    |> Enum.filter(&(&1.kind == :mermaid))
    |> Enum.map(&%{id: &1.id, source: &1.text})
  end

  defp collect([], source_id, index, paragraph, acc) do
    flush_paragraph(paragraph, source_id, index, acc)
  end

  defp collect([line | rest], source_id, index, paragraph, acc) do
    case Regex.run(@fence_re, line) do
      [_, language] ->
        {body, remaining} = take_fence(rest, [])
        acc = flush_paragraph(paragraph, source_id, index, acc)
        block = code_block(source_id, index + length(acc), language, Enum.reverse(body))
        collect(remaining, source_id, index + 1, [], [block | acc])

      _other ->
        collect(rest, source_id, index, [line | paragraph], acc)
    end
  end

  defp take_fence([], acc), do: {acc, []}

  defp take_fence([line | rest], acc) do
    if Regex.match?(@fence_re, line) do
      {acc, rest}
    else
      take_fence(rest, [line | acc])
    end
  end

  defp flush_paragraph([], _source_id, _index, acc), do: acc

  defp flush_paragraph(lines, source_id, index, acc) do
    text =
      lines
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim("\n")

    if text == "" do
      acc
    else
      [paragraph_block(source_id, index + length(acc), text) | acc]
    end
  end

  defp paragraph_block(source_id, index, text) do
    RenderedContent.new(
      id: "#{source_id}:block:#{index}",
      source_id: source_id,
      kind: paragraph_kind(text),
      text: text
    )
  end

  defp paragraph_kind(text) do
    cond do
      String.starts_with?(String.trim_leading(text), "#") -> :heading
      String.starts_with?(String.trim_leading(text), ">") -> :blockquote
      Regex.match?(@table_re, text) -> :table
      true -> :markdown
    end
  end

  defp code_block(source_id, index, language, lines) do
    language = normalize_language(language)
    text = Enum.join(lines, "\n")

    RenderedContent.new(
      id: "#{source_id}:block:#{index}",
      source_id: source_id,
      kind: code_kind(language, text),
      text: text,
      language: language
    )
  end

  defp normalize_language(nil), do: nil
  defp normalize_language(""), do: nil
  defp normalize_language(language), do: String.downcase(language)

  defp code_kind(language, _text) when language in ["mermaid", "mmd"], do: :mermaid
  defp code_kind(language, _text) when language in ["diff", "patch"], do: :diff
  defp code_kind(_language, text), do: if(diff_like?(text), do: :diff, else: :code)

  defp diff_like?(text) do
    String.starts_with?(text, ["diff --git", "@@ ", "--- ", "+++ "])
  end

  defp escape_html_line(line) do
    if Regex.match?(~r/<!--.*-->|<\/?[A-Za-z][^>]*>/, line) do
      line
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
    else
      line
    end
  end
end
