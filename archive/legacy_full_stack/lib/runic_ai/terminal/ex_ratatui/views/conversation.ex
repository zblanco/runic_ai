defmodule RunicAI.Terminal.ExRatatui.Views.Conversation do
  @moduledoc false

  alias ExRatatui.Widgets.{Paragraph, Scrollbar, WidgetList}
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Content
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: WidgetList.t()
  def widget(%Model{} = model), do: widget(model, nil, nil)

  @spec widget(Model.t(), pos_integer() | nil, pos_integer() | nil) :: WidgetList.t()
  def widget(%Model{} = model, viewport_rows, viewport_width) do
    messages = visible_messages(model.messages)
    items = items(messages, model, viewport_width)

    selected = selected_index(messages, model.selected_message_id)

    scroll_offset =
      scroll_offset(items, selected, viewport_rows, model.conversation_scrollback_rows)

    %WidgetList{
      items: items,
      selected: selected,
      scroll_offset: scroll_offset,
      block: Helpers.block(title(messages, items, viewport_rows, scroll_offset), model),
      highlight_style: Theme.style(:selected, model)
    }
  end

  @spec scrollbar(WidgetList.t(), Model.t(), pos_integer() | nil) :: Scrollbar.t() | nil
  def scrollbar(%WidgetList{} = widget, %Model{} = model, viewport_rows) do
    content_height = content_height(widget.items)
    max_offset = max_scroll_offset(widget.items, viewport_rows)

    if max_offset == 0 do
      nil
    else
      %Scrollbar{
        orientation: :vertical_right,
        content_length: content_height,
        viewport_content_length: viewport_rows,
        position: widget.scroll_offset,
        thumb_style: Theme.style(:selected, model),
        track_style: Theme.style(:muted, model),
        thumb_symbol: "#",
        track_symbol: "|"
      }
    end
  end

  defp visible_messages(messages) do
    substantive =
      Enum.reject(messages, fn message ->
        Map.get(message, :transient, false) or
          (message.message_kind in ["summary"] and message.role == "assistant")
      end)

    case substantive do
      [] -> messages
      visible -> visible
    end
  end

  defp items(messages, %Model{} = model, viewport_width) do
    messages
    |> Enum.map(fn message ->
      {
        Content.message_widget(message, model, viewport_width),
        Content.message_height(message, model, viewport_width)
      }
    end)
    |> case do
      [] ->
        [
          {
            %Paragraph{
              text: "Ask the assistant from the composer below.",
              style: Theme.style(:muted, model),
              wrap: true
            },
            1
          }
        ]

      items ->
        items
    end
  end

  defp title(messages, items, rows, offset) do
    max_offset = max_scroll_offset(items, rows)
    position = scroll_position(offset, max_offset)

    "Conversation #{length(messages)} | #{position} | PgUp/PgDn"
  end

  defp scroll_offset(_items, _selected, nil, _scrollback_rows), do: 0
  defp scroll_offset(_items, _selected, rows, _scrollback_rows) when rows <= 0, do: 0
  defp scroll_offset([], _selected, _rows, _scrollback_rows), do: 0

  defp scroll_offset(items, _selected, rows, scrollback_rows) when scrollback_rows > 0 do
    max_scroll_offset(items, rows)
    |> Kernel.-(scrollback_rows)
    |> max(0)
  end

  defp scroll_offset(items, selected, rows, _scrollback_rows) do
    selected = selected || length(items) - 1

    selected_bottom =
      items
      |> Enum.take(selected + 1)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    selected_bottom
    |> Kernel.-(rows)
    |> max(0)
    |> min(max_scroll_offset(items, rows))
  end

  defp scroll_position(_offset, 0), do: "all visible"
  defp scroll_position(offset, max_offset) when offset >= max_offset, do: "tail"
  defp scroll_position(0, _max_offset), do: "top"
  defp scroll_position(offset, max_offset), do: "#{max_offset - offset} rows back"

  defp max_scroll_offset(items, nil), do: max(content_height(items) - 1, 0)
  defp max_scroll_offset(items, rows), do: max(content_height(items) - rows, 0)

  defp content_height(items) do
    items
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
  end

  defp selected_index([], _id), do: nil

  defp selected_index(rows, nil) do
    rows
    |> length()
    |> Kernel.-(1)
  end

  defp selected_index(rows, id) do
    Enum.find_index(rows, &(&1.id == id))
  end
end
