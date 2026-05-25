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
      objective_lines(model),
      "",
      hitl_lines(model),
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

  defp objective_lines(%Model{} = model) do
    status =
      objective_field(model.progress_summary, :objective_status) ||
        objective_field(model.objective_loop, :status)

    action =
      objective_field(model.progress_summary, :objective_action) ||
        objective_field(model.objective_loop, :action)

    if status || action do
      [
        "Objective: #{status || "unknown"}",
        "  Action: #{action || "-"}",
        "  Iteration: #{objective_iteration(model) || "-"}",
        "  Tasks: open=#{objective_field(model.progress_summary, :objective_open_task_count) || "-"} done=#{objective_field(model.progress_summary, :objective_completed_task_count) || "-"}",
        objective_error_line(model)
      ]
      |> Enum.reject(&is_nil/1)
    else
      ["Objective: none"]
    end
  end

  defp objective_error_line(%Model{} = model) do
    case objective_error(model) do
      nil -> nil
      error -> "  Error: #{Helpers.short(error, 120)}"
    end
  end

  defp objective_error(%Model{} = model) do
    kind =
      objective_field(model.progress_summary, :objective_error_kind) ||
        objective_field(model.objective_loop, :latest_error_kind)

    message =
      objective_field(model.progress_summary, :objective_error_message) ||
        objective_field(model.objective_loop, :latest_error_message) ||
        objective_field(objective_field(model.objective_loop, :latest_error), :message)

    cond do
      present?(kind) and present?(message) -> "#{kind}: #{message}"
      present?(message) -> to_string(message)
      present?(kind) -> to_string(kind)
      true -> nil
    end
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

  defp hitl_lines(%Model{} = model) do
    case Helpers.pending_hitl_items(model) do
      [] ->
        ["HITL: none"]

      items ->
        ["HITL:" | Enum.map(Enum.take(items, 3), &review_line/1)]
    end
  end

  defp review_line(review) do
    details = field(review, :details) || %{}
    reason = field(details, :reason) || field(review, :reason)

    "  #{field(review, :status) || "pending"} #{field(review, :kind) || "review"} #{Helpers.short(reason || field(review, :id), 72)}"
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

  defp objective_iteration(%Model{} = model) do
    current =
      objective_field(model.progress_summary, :objective_iteration) ||
        objective_field(model.objective_loop, :iteration_count)

    max =
      objective_field(model.progress_summary, :objective_max_iterations) ||
        objective_field(model.objective_loop, :max_iterations)

    cond do
      current && max -> "#{current}/#{max}"
      current -> to_string(current)
      true -> nil
    end
  end

  defp objective_field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp objective_field(map, key) when is_map(map), do: Map.get(map, key)
  defp objective_field(_map, _key), do: nil

  defp present?(value), do: value not in [nil, ""]

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil
end
