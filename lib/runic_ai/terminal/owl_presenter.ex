defmodule RunicAI.Terminal.OwlPresenter do
  @moduledoc """
  Owl/Bunt renderer for `RunicAI.Terminal.Event`.

  The module returns strings so existing Mix shell and test output callbacks can
  remain unchanged. Owl is used for width-aware terminal structures; Bunt is
  used through `RunicAI.Terminal.Theme` for the Runic default palette.
  """

  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.EventPresenter
  alias RunicAI.Terminal.Theme

  @spec render_header(map() | keyword(), keyword()) :: String.t()
  def render_header(opts, renderer_opts \\ []) do
    opts = Map.new(opts)

    content =
      [
        field_line("session", value(opts, :session_id, "auto")),
        field_line("workspace", value(opts, :cwd, File.cwd!())),
        field_line("agent", value(opts, :agent, :standard)),
        field_line("model", value(opts, :model, "default")),
        field_line("client", value(opts, :client, "default")),
        field_line("mode", value(opts, :mode, "verify")),
        field_line("approval", value(opts, :approve, "ask")),
        field_line("detail", value(opts, :detail, :collapsed)),
        field_line("renderer", value(opts, :renderer, :owl)),
        field_line("theme", value(opts, :theme, :runic)),
        maybe_field_line("async", value(opts, :async, nil)),
        maybe_field_line("concurrency", value(opts, :max_concurrency, nil)),
        maybe_field_line("llm map", value(opts, :max_llm_map_concurrency, nil)),
        maybe_field_line("map calls", value(opts, :max_llm_map_calls, nil)),
        maybe_field_line("jsonl", value(opts, :jsonl_path, nil))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    content
    |> box("RunicAI agent", renderer_opts)
    |> Theme.format(:text, renderer_opts)
  end

  @spec render_event(Event.t(), keyword()) :: String.t()
  def render_event(%Event{} = event, opts \\ []) do
    detail = Keyword.get(opts, :detail, :collapsed)
    width = terminal_width(opts)

    [summary | detail_lines] =
      event
      |> EventPresenter.render_event(
        detail: detail,
        graph: Keyword.get(opts, :graph, :text),
        color: Keyword.get(opts, :color, :auto)
      )
      |> String.split("\n")

    token = Theme.token_for(event)

    [
      summary |> truncate(width) |> Theme.format(token, opts),
      render_detail_lines(detail_lines, width, opts)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @spec render_final_report(map(), keyword()) :: String.t()
  def render_final_report(result, opts \\ []) when is_map(result) do
    boxed_report =
      result
      |> without_rendered_diagrams()
      |> final_report_content(opts)
      |> box("Final report", opts)
      |> Theme.format(:text, opts)

    [boxed_report, rendered_diagram_blocks(result, opts)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @spec render_review_prompt(ReviewRequest.t(), keyword()) :: String.t()
  def render_review_prompt(%ReviewRequest{} = request, opts \\ []) do
    request
    |> EventPresenter.render_review_prompt()
    |> box("Review required", opts)
    |> Theme.format(:review, opts)
  end

  defp final_report_content(result, opts) do
    report = EventPresenter.render_final_report(result, opts)
    rows = report_rows(report)
    width = max(terminal_width(opts) - 8, 32)

    cond do
      rows == [] ->
        report

      true ->
        rows
        |> Enum.map_join("\n", &report_row(&1, width))
    end
  end

  defp report_rows(report) do
    report
    |> String.split("\n")
    |> Enum.reduce([], &accumulate_report_line/2)
    |> Enum.reverse()
    |> Enum.reject(&(&1.field == ""))
  end

  defp without_rendered_diagrams(result) do
    update_summary(result, fn summary ->
      summary
      |> Map.delete(:rendered_diagrams)
      |> Map.delete("rendered_diagrams")
    end)
  end

  defp update_summary(result, fun) do
    cond do
      is_map(Map.get(result, :summary)) ->
        Map.update!(result, :summary, fun)

      is_map(Map.get(result, "summary")) ->
        Map.update!(result, "summary", fun)

      true ->
        result
    end
  end

  defp rendered_diagram_blocks(result, opts) do
    diagrams = rendered_diagrams(result)

    if diagrams == [] do
      nil
    else
      width = terminal_width(opts)

      diagrams
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {diagram, index} ->
        rendered_diagram_lines(diagram, index, width)
      end)
      |> then(&(["", "Rendered diagrams"] ++ &1))
      |> Enum.join("\n")
      |> Theme.format(:text, opts)
    end
  end

  defp rendered_diagrams(result) do
    summary = Map.get(result, :summary) || Map.get(result, "summary") || %{}
    summary[:rendered_diagrams] || summary["rendered_diagrams"] || []
  end

  defp rendered_diagram_lines(diagram, index, width) do
    rendered = field(diagram, :rendered)

    [
      "",
      "#{index}. #{rendered_diagram_label(diagram)}",
      maybe_diagram_line("   status", field(diagram, :status)),
      maybe_diagram_line("   error", field(diagram, :error)),
      rendered && rendered_block(rendered, width)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp rendered_diagram_label(diagram) do
    [
      field(diagram, :path),
      field(diagram, :heading) && "heading #{field(diagram, :heading)}",
      field(diagram, :diagram_index) && "diagram #{field(diagram, :diagram_index)}",
      field(diagram, :line_start) && "line #{field(diagram, :line_start)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> "inline Mermaid source"
      label -> label
    end
  end

  defp maybe_diagram_line(_label, nil), do: nil
  defp maybe_diagram_line(_label, ""), do: nil
  defp maybe_diagram_line(label, value), do: "#{label}: #{value}"

  defp rendered_block(rendered, width) do
    rendered
    |> String.trim_trailing()
    |> String.split("\n", trim: false)
    |> Enum.map(&truncate(&1, width))
  end

  defp accumulate_report_line("Final report", rows), do: rows
  defp accumulate_report_line("", rows), do: append_report_continuation(rows, "")

  defp accumulate_report_line("  " <> line, rows) do
    case String.split(line, ":", parts: 2) do
      [field, value] ->
        field = String.trim(field)

        if report_field?(field) do
          [%{field: field, value: String.trim_leading(value)} | rows]
        else
          append_report_continuation(rows, line)
        end

      _other ->
        append_report_continuation(rows, line)
    end
  end

  defp accumulate_report_line(line, rows), do: append_report_continuation(rows, line)

  defp append_report_continuation([], line), do: [%{field: "", value: line}]

  defp append_report_continuation([row | rows], line) do
    value =
      case row.value do
        "" -> line
        value -> value <> "\n" <> line
      end

    [%{row | value: value} | rows]
  end

  defp report_row(%{field: field, value: ""}, _width), do: "#{field}:"

  defp report_row(%{field: "rendered diagrams", value: value}, width) do
    lines =
      value
      |> String.split("\n")
      |> Enum.map(&truncate(&1, max(width - 2, 16)))

    multiline_report_row("rendered diagrams", lines)
  end

  defp report_row(%{field: field, value: value}, width) do
    lines = wrap_text(value, width - 2)

    case lines do
      [single] ->
        if String.length("#{field}: #{single}") <= width do
          "#{field}: #{single}"
        else
          multiline_report_row(field, lines)
        end

      _other ->
        multiline_report_row(field, lines)
    end
  end

  defp multiline_report_row(field, lines) do
    [field <> ":" | Enum.map(lines, &("  " <> &1))]
    |> Enum.join("\n")
  end

  defp report_field?(field) do
    field in [
      "status",
      "session",
      "run",
      "objective",
      "changed files",
      "tools used",
      "rendered diagrams",
      "artifacts",
      "risks",
      "reply",
      "persistence"
    ]
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp wrap_text(value, width) do
    value
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case wrap_line(String.trim_trailing(line), width, []) do
        [] -> [""]
        wrapped -> wrapped
      end
    end)
  end

  defp wrap_line("", _width, []), do: []
  defp wrap_line("", _width, acc), do: Enum.reverse(acc)

  defp wrap_line(line, width, acc) do
    if String.length(line) <= width do
      Enum.reverse([line | acc])
    else
      {head, rest} = split_line(line, width)
      wrap_line(String.trim_leading(rest), width, [head | acc])
    end
  end

  defp split_line(line, width) do
    candidate = String.slice(line, 0, width + 1)

    case candidate |> String.graphemes() |> Enum.find_index(&(&1 == " ")) do
      nil ->
        {String.slice(line, 0, width), String.slice(line, width..-1//1) || ""}

      _index ->
        split_at =
          candidate
          |> String.graphemes()
          |> Enum.with_index()
          |> Enum.filter(fn {grapheme, _index} -> grapheme == " " end)
          |> List.last()
          |> elem(1)

        {String.slice(line, 0, split_at), String.slice(line, (split_at + 1)..-1//1) || ""}
    end
  end

  defp render_detail_lines([], _width, _opts), do: []

  defp render_detail_lines(lines, width, opts) do
    Enum.map(lines, fn line ->
      line
      |> truncate(width)
      |> Theme.format(:muted, opts)
    end)
  end

  defp box(content, title, opts) do
    if unicode?(opts) do
      content
      |> Owl.Box.new(
        title: title,
        padding_x: 1,
        border_style: :solid_rounded,
        max_width: terminal_width(opts)
      )
      |> to_string()
    else
      ascii_box(content, title)
    end
  end

  defp ascii_box(content, title) do
    lines = String.split(content, "\n")

    width =
      lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end) |> max(String.length(title))

    rule = "+" <> String.duplicate("-", width + 2) <> "+"

    body =
      lines
      |> Enum.map(fn line -> "| " <> String.pad_trailing(line, width) <> " |" end)
      |> Enum.join("\n")

    [rule, "| " <> String.pad_trailing(title, width) <> " |", rule, body, rule]
    |> Enum.join("\n")
  end

  defp field_line(label, value),
    do: String.pad_trailing(to_string(label) <> ":", 11) <> to_string(value)

  defp maybe_field_line(_label, nil), do: nil
  defp maybe_field_line(label, value), do: field_line(label, value)

  defp value(opts, key, default) do
    case Map.fetch(opts, key) do
      {:ok, value} when not is_nil(value) ->
        value

      _other ->
        case Map.fetch(opts, Atom.to_string(key)) do
          {:ok, value} when not is_nil(value) -> value
          _other -> default
        end
    end
  end

  defp terminal_width(opts) do
    Keyword.get(opts, :width) || Owl.IO.columns() || 100
  end

  defp truncate(text, width) do
    text
    |> Owl.Data.truncate(max(width, 20))
    |> to_string()
  end

  defp unicode?(opts), do: Keyword.get(opts, :unicode, :auto) != :never
end
