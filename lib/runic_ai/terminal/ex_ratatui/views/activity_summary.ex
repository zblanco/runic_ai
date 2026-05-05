defmodule RunicAI.Terminal.ExRatatui.Views.ActivitySummary do
  @moduledoc false

  alias ExRatatui.Widgets.Paragraph
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: Paragraph.t()
  def widget(%Model{} = model) do
    %Paragraph{
      text: text(model),
      style: Theme.style(:muted, model),
      wrap: false
    }
  end

  defp text(%Model{} = model) do
    run = Model.selected_run(model)
    latest_scorecard = List.last(model.scorecards)

    [
      "thread=#{Helpers.short(model.session_id, 24)}",
      "run=#{Helpers.short(model.selected_run_id, 24)}",
      "run_status=#{(run && run.status) || model.status}",
      "active=#{model.active_run?}",
      "msgs=#{length(model.messages)}",
      "events=#{length(model.timeline)}",
      "tools=#{length(model.tool_calls)}",
      "hitl=#{pending_reviews(model.review_requests)}",
      "artifacts=#{length(model.artifacts)}",
      "repairs=#{length(model.repairs)}",
      scorecard_summary(latest_scorecard)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" | ")
  end

  defp pending_reviews(reviews) do
    reviews
    |> Enum.count(&(&1.status in ["pending", "review"]))
  end

  defp scorecard_summary(nil), do: "scorecard=none"
  defp scorecard_summary(scorecard), do: "scorecard=#{scorecard.objective_status || "unknown"}"
end
