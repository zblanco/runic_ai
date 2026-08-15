defmodule RunicAI.Terminal.ExRatatui.Views.Timeline do
  @moduledoc false

  alias ExRatatui.Widgets.{Paragraph, WidgetList}
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: WidgetList.t()
  def widget(%Model{} = model) do
    events = if search_active?(model), do: model.search_results, else: model.timeline

    items =
      Enum.map(events, fn event ->
        {%Paragraph{text: line(event), style: Theme.status_style(field(event, :status), model)},
         1}
      end)

    %WidgetList{
      items: items,
      selected: selected_index(events, model.selected_event_id),
      block: Helpers.block(title(model), model),
      highlight_style: Theme.style(:selected, model)
    }
  end

  defp title(%Model{} = model) do
    if search_active?(model) do
      search_title(model)
    else
      "Timeline #{length(model.timeline)}"
    end
  end

  defp search_title(%Model{search_results: results, search_term: term}),
    do: "Search #{term} #{length(results)}"

  defp search_active?(%Model{search_term: term}) when is_binary(term), do: String.trim(term) != ""
  defp search_active?(_model), do: false

  defp line(event) do
    [
      Helpers.time(field(event, :at)),
      String.upcase(to_string(field(event, :status) || "-")),
      field(event, :kind),
      field(event, :phase),
      Helpers.short(field(event, :title) || field(event, :detail) || field(event, :id), 76)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp selected_index(rows, id), do: Enum.find_index(rows, &(field(&1, :id) == id))

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_other, _key), do: nil
end
