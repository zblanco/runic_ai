defmodule RunicAI.Terminal.ExRatatui.Views.Root do
  @moduledoc false

  alias ExRatatui.Frame
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Views.ActivitySummary
  alias RunicAI.Terminal.ExRatatui.Views.Composer
  alias RunicAI.Terminal.ExRatatui.Views.Conversation
  alias RunicAI.Terminal.ExRatatui.Views.Details
  alias RunicAI.Terminal.ExRatatui.Views.Evals
  alias RunicAI.Terminal.ExRatatui.Views.ManagedWorkflows
  alias RunicAI.Terminal.ExRatatui.Views.ReviewModal
  alias RunicAI.Terminal.ExRatatui.Views.RunPicker
  alias RunicAI.Terminal.ExRatatui.Views.StatusBar
  alias RunicAI.Terminal.ExRatatui.Views.Suggestions
  alias RunicAI.Terminal.ExRatatui.Views.Timeline
  alias RunicAI.Terminal.ExRatatui.Views.WorkflowGraph

  @spec render(Model.t(), Frame.t()) :: [{ExRatatui.widget(), Rect.t()}]
  def render(%Model{view_mode: :chat} = model, %Frame{} = frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    {header, summary, conversation, suggestions_area, composer} = chat_areas(area, model)

    conversation_rows = max(conversation.height - 2, 1)
    conversation_widget = Conversation.widget(model, conversation_rows, conversation.width)

    [
      {StatusBar.widget(model), header},
      {ActivitySummary.widget(model), summary},
      {conversation_widget, conversation},
      {Composer.widget(model), composer}
    ]
    |> maybe_add_conversation_scrollbar(
      conversation_widget,
      model,
      conversation_rows,
      conversation
    )
    |> maybe_add_suggestions(model, suggestions_area)
    |> maybe_add_review(model, area)
  end

  def render(%Model{} = model, %Frame{} = frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    {header, body, lower, suggestions_area, composer} = debug_areas(area, model)

    [runs, timeline, detail] =
      split(body, :horizontal, [{:percentage, 28}, {:percentage, 42}, {:min, 20}])

    [managed, graph, evals] =
      split(lower, :horizontal, [{:percentage, 34}, {:percentage, 33}, {:min, 20}])

    widgets = [
      {StatusBar.widget(model), header},
      {RunPicker.widget(model), runs},
      {Timeline.widget(model), timeline},
      {Details.widget(model), detail},
      {ManagedWorkflows.widget(model), managed},
      {WorkflowGraph.widget(model), graph},
      {Evals.widget(model), evals},
      {Composer.widget(model), composer}
    ]

    widgets
    |> maybe_add_suggestions(model, suggestions_area)
    |> maybe_add_review(model, area)
  end

  defp chat_areas(area, %Model{} = model) do
    case Suggestions.widget(model) do
      nil ->
        [header, summary, conversation, composer] =
          split(area, :vertical, [{:length, 1}, {:length, 1}, {:min, 10}, {:length, 4}])

        {header, summary, conversation, nil, composer}

      _widget ->
        [header, summary, conversation, suggestions, composer] =
          split(area, :vertical, [
            {:length, 1},
            {:length, 1},
            {:min, 10},
            {:length, 4},
            {:length, 4}
          ])

        {header, summary, conversation, suggestions, composer}
    end
  end

  defp debug_areas(area, %Model{} = model) do
    case Suggestions.widget(model) do
      nil ->
        [header, body, lower, composer] =
          split(area, :vertical, [{:length, 1}, {:min, 10}, {:length, 7}, {:length, 4}])

        {header, body, lower, nil, composer}

      _widget ->
        [header, body, lower, suggestions, composer] =
          split(area, :vertical, [
            {:length, 1},
            {:min, 10},
            {:length, 7},
            {:length, 4},
            {:length, 4}
          ])

        {header, body, lower, suggestions, composer}
    end
  end

  defp maybe_add_suggestions(widgets, _model, nil), do: widgets

  defp maybe_add_suggestions(widgets, %Model{} = model, %Rect{} = area) do
    case Suggestions.widget(model) do
      nil -> widgets
      widget -> widgets ++ [{widget, area}]
    end
  end

  defp maybe_add_conversation_scrollbar(
         widgets,
         conversation_widget,
         %Model{} = model,
         rows,
         area
       ) do
    case Conversation.scrollbar(conversation_widget, model, rows) do
      nil -> widgets
      widget -> widgets ++ [{widget, area}]
    end
  end

  defp maybe_add_review(widgets, %Model{} = model, %Rect{} = area) do
    case ReviewModal.widget(model) do
      nil -> widgets
      popup -> widgets ++ [{popup, area}]
    end
  end

  defp split(area, direction, constraints) do
    case Layout.split(area, direction, constraints) do
      {:error, _reason} -> fallback_split(area, length(constraints))
      rects -> rects
    end
  end

  defp fallback_split(%Rect{} = area, count) do
    height = div(max(area.height, count), count)

    Enum.map(0..(count - 1), fn index ->
      %Rect{x: area.x, y: area.y + index * height, width: area.width, height: height}
    end)
  end
end
