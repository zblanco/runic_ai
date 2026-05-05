defmodule RunicAI.Terminal.ExRatatui.Views.Activity do
  @moduledoc false

  alias ExRatatui.Widgets.Paragraph
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: Paragraph.t()
  def widget(%Model{} = model) do
    %Paragraph{
      text: text(model),
      block: Helpers.block("Agent Activity", model),
      wrap: true
    }
  end

  defp text(%Model{} = model) do
    [
      run_lines(model),
      "",
      hitl_lines(model.review_requests),
      "",
      tool_lines(model.tool_calls),
      "",
      artifact_lines(model.artifacts),
      "",
      scorecard_lines(model.scorecards),
      "",
      repair_lines(model.repairs)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp run_lines(%Model{} = model) do
    run = Model.selected_run(model)

    [
      "Run: #{model.selected_run_id || "none"}",
      "Status: #{(run && run.status) || model.status}",
      "Mode: #{model.view_mode}",
      "Active: #{model.active_run?}"
    ]
  end

  defp hitl_lines([]), do: ["HITL: none"]

  defp hitl_lines(reviews) do
    pending = Enum.filter(reviews, &(&1.status in ["pending", "review"]))

    case pending do
      [] ->
        ["HITL: none"]

      reviews ->
        ["HITL:" | Enum.map(Enum.take(reviews, 3), &review_line/1)]
    end
  end

  defp review_line(review) do
    reason = get_in(review.details || %{}, ["reason"]) || get_in(review.details || %{}, [:reason])
    "  #{review.status} #{review.kind || "review"} #{Helpers.short(reason || review.id, 72)}"
  end

  defp tool_lines([]), do: ["Tools: none"]

  defp tool_lines(tools) do
    ["Tools:" | Enum.map(Enum.take(tools, -5), &tool_line/1)]
  end

  defp tool_line(tool) do
    "  #{tool.status || "running"} #{tool.tool_name || "tool"} #{Helpers.short(tool.args, 72)}"
  end

  defp artifact_lines([]), do: ["Artifacts: none"]

  defp artifact_lines(artifacts) do
    ["Artifacts:" | Enum.map(Enum.take(artifacts, -4), &artifact_line/1)]
  end

  defp artifact_line(artifact) do
    "  #{artifact.kind || "artifact"} #{artifact.path || artifact.id}"
  end

  defp scorecard_lines([]), do: ["Scorecard: none"]

  defp scorecard_lines(scorecards) do
    latest = List.last(scorecards)
    risks = latest.data |> Map.get("residual_risks", Map.get(latest.data, :residual_risks, []))
    ["Scorecard: #{latest.objective_status}", "Risks: #{length(List.wrap(risks))}"]
  end

  defp repair_lines([]), do: ["Repairs: none"]

  defp repair_lines(repairs) do
    ["Repairs:" | Enum.map(Enum.take(repairs, -3), &"  #{&1.status} #{&1.strategy}")]
  end
end
