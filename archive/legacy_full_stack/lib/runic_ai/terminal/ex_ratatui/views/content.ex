defmodule RunicAI.Terminal.ExRatatui.Views.Content do
  @moduledoc false

  alias ExRatatui.Text
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Markdown, Paragraph}
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.RenderCache
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.MarkdownBlocks
  alias RunicAI.Terminal.Syntax

  @default_wrap_width 88
  @max_rows 10_000

  @spec message_widget(map(), Model.t(), pos_integer() | nil) :: ExRatatui.widget()
  def message_widget(message, %Model{} = model, viewport_width \\ nil) when is_map(message) do
    content = message_content(message)
    blocks = message_blocks(message, model, viewport_width)

    cond do
      Enum.any?(blocks, &(&1.kind == :mermaid)) ->
        %Paragraph{
          text: message_lines(message, model, blocks),
          style: message_style(message, model),
          wrap: true
        }

      markdown_message?(message, content) ->
        %Markdown{
          content: markdown_message_text(message, content),
          style: message_style(message, model),
          wrap: true
        }

      true ->
        %Paragraph{
          text: plain_message_text(message, content),
          style: message_style(message, model),
          wrap: true
        }
    end
  end

  @spec message_height(map(), pos_integer() | nil) :: non_neg_integer()
  def message_height(message, viewport_width \\ nil) when is_map(message) do
    message
    |> message_text_for_height()
    |> wrapped_height(viewport_width)
    |> min(@max_rows)
    |> max(2)
  end

  @spec message_height(map(), Model.t(), pos_integer() | nil) :: non_neg_integer()
  def message_height(message, %Model{} = model, viewport_width) when is_map(message) do
    message
    |> message_widget(model, viewport_width)
    |> widget_height(viewport_width)
    |> min(@max_rows)
    |> max(2)
  end

  @spec message_text_for_height(map()) :: String.t()
  def message_text_for_height(message) when is_map(message) do
    plain_message_text(message, message_content(message))
  end

  @spec graph_block_text(String.t(), Model.t(), String.t()) :: String.t()
  def graph_block_text(source, %Model{} = model, source_id) do
    graph_source = %{
      key: RenderCache.mermaid_source_key(source_id, source),
      title: "Mermaid",
      kind: :mermaid,
      source: source
    }

    case RenderCache.fetch_graph(model.render_cache, graph_source,
           mode: model.graph,
           theme: model.theme
         ) do
      %{warning: warning, output: output} when is_binary(warning) ->
        "graph #{model.graph}: #{warning}\n#{output}"

      %{output: output} when is_binary(output) and output != "" ->
        output

      _other ->
        case model.graph do
          :mmdflux -> "Rendering Mermaid diagram with MMDFlux..."
          _other -> source
        end
    end
  end

  defp message_lines(message, %Model{} = model, blocks) do
    header = [
      Line.new([Span.new(role_header(message), style: message_style(message, model))])
    ]

    body =
      Enum.flat_map(blocks, &block_lines(&1, model))

    header ++ [Line.new([Span.new("")])] ++ body
  end

  defp block_lines(%{kind: :mermaid, text: text, id: id}, %Model{} = model) do
    text
    |> graph_block_text(model, id)
    |> String.split("\n", trim: false)
    |> Enum.map(&Line.new([Span.new(&1, style: Theme.style(:purple, model))]))
  end

  defp block_lines(%{kind: kind, text: text, language: language}, %Model{} = model)
       when kind in [:code, :diff] do
    language = Syntax.language_for(language, text)

    text
    |> Syntax.tokenize(language)
    |> Enum.map(fn tokens ->
      tokens
      |> Enum.map(fn token -> Span.new(token.text, style: syntax_style(token.role, model)) end)
      |> Line.new()
    end)
  end

  defp block_lines(%{text: text}, %Model{} = model) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map(&Line.new([Span.new(&1, style: Theme.style(:text, model))]))
  end

  defp markdown_message_text(message, content) do
    content =
      content
      |> Kernel.||("")
      |> String.trim()
      |> MarkdownBlocks.escape_raw_html()

    "#{role_header(message)}\n\n#{content}"
  end

  defp plain_message_text(message, content) do
    """
    #{role_header(message)}
    #{String.trim(content || "")}
    """
    |> String.trim()
  end

  defp role_header(message) do
    role =
      case message.role do
        "user" -> "You"
        "assistant" -> "Assistant"
        other when is_binary(other) -> String.capitalize(other)
        _other -> "Message"
      end

    kind = message.message_kind || "message"

    stream =
      if Map.get(message, :stream_complete) == false do
        " / streaming"
      else
        ""
      end

    "#{role} / #{kind}#{stream}"
  end

  defp message_content(message) do
    message.content || inspect(message.content_json || %{}, limit: 10, printable_limit: 2_000)
  end

  defp message_blocks(message, %Model{} = model, viewport_width) do
    source = RenderCache.markdown_source(message)

    case cached_markdown_blocks(model, source, viewport_width) do
      %{blocks: blocks} when is_list(blocks) ->
        blocks

      _other ->
        MarkdownBlocks.parse(message_content(message), source_id: message.id || "message")
    end
  end

  defp cached_markdown_blocks(_model, nil, _viewport_width), do: nil

  defp cached_markdown_blocks(%Model{} = model, source, viewport_width) do
    RenderCache.fetch_markdown(model.render_cache, source,
      width: viewport_width || :auto,
      theme: model.theme
    ) ||
      RenderCache.fetch_markdown(model.render_cache, source,
        width: :auto,
        theme: model.theme
      )
  end

  defp markdown_message?(message, content) do
    message.role == "assistant" or MarkdownBlocks.markdown?(content)
  end

  defp message_style(%{role: "user"}, model), do: Theme.style(:primary, model)
  defp message_style(%{message_kind: "error"}, model), do: Theme.style(:error, model)
  defp message_style(%{message_kind: "direct_response"}, model), do: Theme.style(:gold, model)
  defp message_style(%{stream_complete: false}, model), do: Theme.style(:primary, model)
  defp message_style(_message, model), do: Theme.style(:text, model)

  defp syntax_style(:comment, model), do: Theme.style(:muted, model)
  defp syntax_style(:keyword, model), do: Theme.style(:purple, model)
  defp syntax_style(:string, model), do: Theme.style(:gold, model)
  defp syntax_style(:number, model), do: Theme.style(:info, model)
  defp syntax_style(:option, model), do: Theme.style(:primary, model)
  defp syntax_style(:command, model), do: Theme.style(:gold, model)
  defp syntax_style(:variable, model), do: Theme.style(:magenta, model)
  defp syntax_style(:diff_added, model), do: Theme.style(:success, model)
  defp syntax_style(:diff_removed, model), do: Theme.style(:error, model)
  defp syntax_style(:diff_hunk, model), do: Theme.style(:info, model)
  defp syntax_style(:diff_path, model), do: Theme.style(:gold, model)
  defp syntax_style(_role, model), do: Theme.style(:text, model)

  defp wrapped_height(text, viewport_width) do
    text
    |> String.split("\n")
    |> Enum.map(&wrapped_rows(&1, wrap_width(viewport_width)))
    |> Enum.sum()
  end

  defp widget_height(%Markdown{content: content}, viewport_width) do
    wrapped_height(content || "", viewport_width)
  end

  defp widget_height(%Paragraph{text: text}, viewport_width) do
    text
    |> text_lines()
    |> Enum.map(&wrapped_rows(&1, wrap_width(viewport_width)))
    |> Enum.sum()
  end

  defp widget_height(_widget, _viewport_width), do: 1

  defp text_lines(%Text{lines: lines}), do: Enum.map(lines, &line_text/1)
  defp text_lines(%Line{} = line), do: [line_text(line)]
  defp text_lines(%Span{} = span), do: [span.content]

  defp text_lines(text) when is_binary(text) do
    String.split(text, "\n", trim: false)
  end

  defp text_lines([]), do: [""]
  defp text_lines([%Line{} | _rest] = lines), do: Enum.map(lines, &line_text/1)
  defp text_lines([%Span{} | _rest] = spans), do: [spans_text(spans)]
  defp text_lines(other), do: String.split(inspect(other), "\n", trim: false)

  defp line_text(%Line{spans: spans}), do: spans_text(spans)
  defp spans_text(spans), do: Enum.map_join(spans, "", &span_text/1)
  defp span_text(%Span{content: content}), do: content
  defp span_text(other), do: inspect(other)

  defp wrapped_rows("", _width), do: 1

  defp wrapped_rows(line, width) do
    line
    |> String.length()
    |> max(1)
    |> then(&ceil(&1 / width))
  end

  defp wrap_width(nil), do: @default_wrap_width
  defp wrap_width(width) when is_integer(width), do: max(width - 4, 24)
end
