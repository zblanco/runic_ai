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
      "hitl=#{Helpers.pending_hitl_count(model)}",
      "artifacts=#{length(model.artifacts)}",
      "repairs=#{length(model.repairs)}",
      objective_summary(model),
      scorecard_summary(latest_scorecard)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" | ")
  end

  defp objective_summary(%Model{} = model) do
    status =
      objective_field(model.progress_summary, :objective_status) ||
        objective_field(model.objective_loop, :status)

    action =
      objective_field(model.progress_summary, :objective_action) ||
        objective_field(model.objective_loop, :action)

    iteration = objective_iteration(model)
    remaining = model.progress_summary |> objective_field(:remaining_ms) |> duration_label()
    error = objective_error(model)

    if Enum.any?([status, action, iteration, remaining, error], &present?/1) do
      [
        "objective=#{status || "unknown"}",
        action && "action=#{action}",
        iteration && "iter=#{iteration}",
        remaining && "remaining=#{remaining}",
        error && "error=#{Helpers.short(error, 48)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
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
      present?(kind) and present?(message) -> "#{kind}:#{message}"
      present?(message) -> to_string(message)
      present?(kind) -> to_string(kind)
      true -> nil
    end
  end

  defp objective_iteration(%Model{} = model) do
    current =
      objective_field(model.progress_summary, :objective_iteration) ||
        objective_field(model.objective_loop, :iteration_count)

    max =
      objective_field(model.progress_summary, :objective_max_iterations) ||
        objective_field(model.objective_loop, :max_iterations)

    cond do
      present?(current) and present?(max) -> "#{current}/#{max}"
      present?(current) -> to_string(current)
      true -> nil
    end
  end

  defp objective_field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp objective_field(map, key) when is_map(map), do: Map.get(map, key)
  defp objective_field(_map, _key), do: nil

  defp present?(value), do: value not in [nil, ""]

  defp duration_label(nil), do: nil
  defp duration_label(value) when is_binary(value), do: value

  defp duration_label(value) when is_integer(value) do
    cond do
      value < 1_000 -> "#{value}ms"
      value < 60_000 -> "#{Float.round(value / 1_000, 1)}s"
      true -> "#{Float.round(value / 60_000, 1)}m"
    end
  end

  defp duration_label(value), do: to_string(value)

  defp scorecard_summary(nil), do: "scorecard=none"
  defp scorecard_summary(scorecard), do: "scorecard=#{scorecard.objective_status || "unknown"}"
end
