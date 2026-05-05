defmodule RunicAI.Terminal.Syntax do
  @moduledoc """
  Lightweight terminal syntax tokenization.

  ExRatatui's Markdown widget provides rich syntax highlighting through the
  Rust side. This module covers RunicAI-specific fallback rendering, especially
  diffs and command snippets that appear in non-Markdown panes.
  """

  @type role ::
          :plain
          | :comment
          | :keyword
          | :string
          | :number
          | :option
          | :command
          | :variable
          | :diff_added
          | :diff_removed
          | :diff_hunk
          | :diff_path

  @type token :: %{role: role(), text: String.t()}
  @type line :: [token()]

  @spec tokenize(String.t(), String.t() | atom() | nil) :: [line()]
  def tokenize(text, language) when is_binary(text) do
    language = normalize_language(language)

    text
    |> String.split("\n", trim: false)
    |> Enum.map(&tokenize_line(&1, language))
  end

  @spec language_for(String.t() | nil, String.t()) :: String.t() | nil
  def language_for(language, text) when is_binary(text) do
    normalize_language(language) || infer_language(text)
  end

  defp tokenize_line(line, "diff"), do: diff_line(line)
  defp tokenize_line(line, "patch"), do: diff_line(line)
  defp tokenize_line(line, "sh"), do: shell_line(line)
  defp tokenize_line(line, "bash"), do: shell_line(line)
  defp tokenize_line(line, "zsh"), do: shell_line(line)
  defp tokenize_line(line, "shell"), do: shell_line(line)
  defp tokenize_line(line, "elixir"), do: simple_code_line(line)
  defp tokenize_line(line, "ex"), do: simple_code_line(line)
  defp tokenize_line(line, "json"), do: json_line(line)
  defp tokenize_line(line, _language), do: [%{role: :plain, text: line}]

  defp diff_line("+++" <> _rest = line), do: [%{role: :diff_path, text: line}]
  defp diff_line("---" <> _rest = line), do: [%{role: :diff_path, text: line}]
  defp diff_line("@@" <> _rest = line), do: [%{role: :diff_hunk, text: line}]
  defp diff_line("+" <> _rest = line), do: [%{role: :diff_added, text: line}]
  defp diff_line("-" <> _rest = line), do: [%{role: :diff_removed, text: line}]
  defp diff_line(line), do: [%{role: :plain, text: line}]

  defp shell_line("#" <> _rest = line), do: [%{role: :comment, text: line}]

  defp shell_line(line) do
    line
    |> String.split(~r/(\s+)/, include_captures: true, trim: false)
    |> Enum.with_index()
    |> Enum.map(fn {part, index} ->
      cond do
        String.trim(part) == "" -> %{role: :plain, text: part}
        index == 0 -> %{role: :command, text: part}
        String.starts_with?(part, "-") -> %{role: :option, text: part}
        String.starts_with?(part, "$") -> %{role: :variable, text: part}
        quoted?(part) -> %{role: :string, text: part}
        true -> %{role: :plain, text: part}
      end
    end)
  end

  defp json_line(line) do
    line
    |> String.split(~r/(\"(?:[^\"\\]|\\.)*\"|-?\d+(?:\.\d+)?|true|false|null)/,
      include_captures: true,
      trim: false
    )
    |> Enum.map(fn part ->
      cond do
        String.starts_with?(part, "\"") -> %{role: :string, text: part}
        part in ["true", "false", "null"] -> %{role: :keyword, text: part}
        Regex.match?(~r/^-?\d/, part) -> %{role: :number, text: part}
        true -> %{role: :plain, text: part}
      end
    end)
  end

  defp simple_code_line(line) do
    line
    |> String.split(
      ~r/(\bdefmodule\b|\bdef\b|\bdo\b|\bend\b|\bcase\b|\bwith\b|\bfn\b|\"(?:[^\"\\]|\\.)*\"|:[A-Za-z_][A-Za-z0-9_?!]*)/,
      include_captures: true,
      trim: false
    )
    |> Enum.map(fn part ->
      cond do
        part in ["defmodule", "def", "do", "end", "case", "with", "fn"] ->
          %{role: :keyword, text: part}

        String.starts_with?(part, "\"") ->
          %{role: :string, text: part}

        String.starts_with?(part, ":") ->
          %{role: :variable, text: part}

        true ->
          %{role: :plain, text: part}
      end
    end)
  end

  defp normalize_language(nil), do: nil

  defp normalize_language(language) when is_atom(language),
    do: language |> Atom.to_string() |> normalize_language()

  defp normalize_language(language) when is_binary(language) do
    case String.downcase(language) do
      "" -> nil
      "shell-session" -> "shell"
      "console" -> "shell"
      "iex" -> "elixir"
      other -> other
    end
  end

  defp infer_language(text) do
    cond do
      String.starts_with?(text, ["diff --git", "@@", "+++", "---"]) -> "diff"
      String.trim_leading(text) |> String.starts_with?(["{", "["]) -> "json"
      true -> nil
    end
  end

  defp quoted?(part), do: String.starts_with?(part, ["\"", "'"])
end
