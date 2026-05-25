defmodule RunicAI.Terminal.ExRatatui.Views.Details do
  @moduledoc false

  alias ExRatatui.Widgets.Markdown
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Redaction
  alias RunicAI.Terminal.ExRatatui.Views.Helpers
  alias RunicAI.Terminal.MarkdownBlocks

  @spec widget(Model.t()) :: Markdown.t()
  def widget(%Model{} = model) do
    %Markdown{
      content: content(model),
      block: Helpers.block(title(model), model),
      wrap: true
    }
  end

  defp title(%Model{detail_mode: :prompt_context}), do: "Prompt / Context"
  defp title(_model), do: "Detail / Evidence"

  defp content(%Model{detail_visible?: false}), do: "detail hidden"
  defp content(%Model{detail_mode: :prompt_context} = model), do: prompt_context_markdown(model)

  defp content(%Model{} = model) do
    event = Model.selected_event(model)

    [
      "## Messages",
      message_lines(model.messages),
      "",
      "## Selected Event",
      selected_event_lines(event),
      "",
      "## Scorecard",
      scorecard_lines(model.scorecards),
      "",
      "## Reviews",
      review_lines(model),
      "",
      "## Objective Loop",
      objective_loop_lines(model),
      "",
      "## Tools",
      tool_lines(model.tool_calls),
      "",
      "## Artifacts",
      artifact_lines(model.artifacts),
      "",
      "## Repairs",
      repair_lines(model.repairs),
      "",
      "## Runnables",
      runnable_lines(model.runnable_events),
      "",
      "## Logs",
      log_lines(Model.filtered_logs(model)),
      "",
      "## Signals",
      signal_lines(model.signal_views)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> MarkdownBlocks.escape_raw_html()
  end

  defp selected_event_lines(nil), do: ["No event selected."]

  defp selected_event_lines(event) do
    [
      "- sequence: #{event.sequence || "-"}",
      "- status: #{event.status}",
      "- kind: #{event.kind}/#{event.phase || "-"}",
      "- title: #{short(event.title, 160)}",
      "- detail: #{short(event.detail, 240)}",
      fenced("event data", event.data)
    ]
  end

  defp message_lines([]), do: ["Messages: none"]

  defp message_lines(messages) do
    Enum.map(Enum.take(messages, -3), &message_line/1)
  end

  defp message_line(message) do
    role = message.role || "assistant"
    kind = message.message_kind || "message"
    content = message.content || Helpers.short(message.content_json, 220)
    "- #{role}/#{kind}: #{short(content, 300)}"
  end

  defp scorecard_lines([]), do: ["Scorecard: none"]

  defp scorecard_lines(scorecards) do
    latest = List.last(scorecards)
    ["- status: #{latest.objective_status}", fenced("scorecard", latest.data)]
  end

  defp review_lines(%Model{} = model) do
    pending_items = Helpers.pending_hitl_items(model)

    if model.review_requests == [] and pending_items == [] do
      ["Reviews: none"]
    else
      [
        "- total: #{length(model.review_requests)}",
        "- pending: #{length(pending_items)}",
        objective_pending_line(model, :pending_review_requests, "objective reviews"),
        objective_pending_line(model, :pending_budget_requests, "objective budgets")
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  defp objective_pending_line(%Model{} = model, key, label) do
    count =
      model.objective_loop
      |> field(key)
      |> List.wrap()
      |> Enum.count(&is_map/1)

    if count > 0, do: "- #{label}: #{count}"
  end

  defp objective_loop_lines(%Model{} = model) do
    status =
      field(model.progress_summary, :objective_status) || field(model.objective_loop, :status)

    action =
      field(model.progress_summary, :objective_action) || field(model.objective_loop, :action)

    if status || action do
      [
        "- status: #{status || "-"}",
        "- action: #{action || "-"}",
        "- objective: #{short(field(model.progress_summary, :objective) || field(model.objective_loop, :objective), 180)}",
        "- iteration: #{objective_iteration(model) || "-"}",
        "- tasks: open=#{field(model.progress_summary, :objective_open_task_count) || "-"} done=#{field(model.progress_summary, :objective_completed_task_count) || "-"}",
        "- remaining: #{model.progress_summary |> field(:remaining_ms) |> duration_label() || "-"}",
        objective_error_line(model),
        "- latest: #{short(field(model.progress_summary, :latest_event_title), 160)}"
      ]
      |> Enum.reject(&is_nil/1)
    else
      ["Objective loop: none"]
    end
  end

  defp objective_error_line(%Model{} = model) do
    case objective_error(model) do
      nil -> nil
      error -> "- error: #{short(error, 180)}"
    end
  end

  defp objective_error(%Model{} = model) do
    kind =
      field(model.progress_summary, :objective_error_kind) ||
        field(model.objective_loop, :latest_error_kind)

    message =
      field(model.progress_summary, :objective_error_message) ||
        field(model.objective_loop, :latest_error_message) ||
        field(field(model.objective_loop, :latest_error), :message)

    cond do
      present?(kind) and present?(message) -> "#{kind}: #{message}"
      present?(message) -> to_string(message)
      present?(kind) -> to_string(kind)
      true -> nil
    end
  end

  defp tool_lines([]), do: ["Tools: none"]

  defp tool_lines(tools) do
    Enum.map(Enum.take(tools, -6), &tool_line/1)
  end

  defp tool_line(tool) do
    "- #{tool.status || "unknown"} #{tool.tool_name || "tool"} #{short(tool.args, 220)}"
  end

  defp artifact_lines([]), do: ["Artifacts: none"]

  defp artifact_lines(artifacts) do
    Enum.map(Enum.take(artifacts, 5), &"- #{&1.kind} #{&1.path || &1.id}")
  end

  defp repair_lines([]), do: ["Repairs: none"]

  defp repair_lines(repairs) do
    Enum.map(Enum.take(repairs, 5), &"- #{&1.sequence} #{&1.status} #{&1.strategy}")
  end

  defp runnable_lines([]), do: ["Runnables: none"]

  defp runnable_lines(events) do
    Enum.map(Enum.take(events, 6), &"- #{&1.sequence} #{&1.status} #{&1.node_name}")
  end

  defp log_lines([]), do: ["Logs: none"]

  defp log_lines(logs) do
    Enum.map(Enum.take(logs, -6), &log_line/1)
  end

  defp log_line(%{at: at, level: level, message: message, source: source}) do
    source =
      case source do
        nil -> ""
        "" -> ""
        value -> " #{Helpers.short(value, 32)}"
      end

    "- #{at} [#{level}]#{source} #{short(message, 180)}"
  end

  defp log_line(value), do: "- #{short(value, 220)}"

  defp signal_lines(signals) when map_size(signals) == 0, do: []

  defp signal_lines(signals) do
    [
      "- recall: #{length(signals.session_recall || [])}",
      "- prefetch: #{length(signals.prefetch_candidates || [])}",
      "- delegation: #{length(signals.delegation_summaries || [])}"
    ]
  end

  defp objective_iteration(%Model{} = model) do
    current =
      field(model.progress_summary, :objective_iteration) ||
        field(model.objective_loop, :iteration_count)

    max =
      field(model.progress_summary, :objective_max_iterations) ||
        field(model.objective_loop, :max_iterations)

    cond do
      current && max -> "#{current}/#{max}"
      current -> to_string(current)
      true -> nil
    end
  end

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

  defp prompt_context_markdown(%Model{} = model) do
    run = Model.selected_run(model)
    event = Model.selected_event(model)

    [
      "## Run",
      "- run: #{short(model.selected_run_id || "-")}",
      "- thread: #{short(model.session_id || "-")}",
      "- model: #{short(model.model || field(run && run.metadata, :model) || "-")}",
      "- cwd: #{short(model.cwd || "-")}",
      "- objective: #{short((run && run.objective) || "-")}",
      "",
      "## Conversation Tail",
      conversation_context_lines(model.messages),
      "",
      "## Selected Event Prompt",
      selected_event_prompt(event),
      "",
      "## Selected Event Data",
      fenced("event data", event && event.data)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> MarkdownBlocks.escape_raw_html()
  end

  defp conversation_context_lines([]), do: ["No conversation messages."]

  defp conversation_context_lines(messages) do
    messages
    |> Enum.reject(&Map.get(&1, :transient, false))
    |> Enum.take(-8)
    |> Enum.flat_map(fn message ->
      [
        "### #{message.role || "message"} / #{message.message_kind || "message"}",
        "",
        fenced("content", message.content || message.content_json, "text")
      ]
    end)
  end

  defp selected_event_prompt(nil), do: "No event selected."

  defp selected_event_prompt(event) do
    event
    |> prompt_text()
    |> case do
      nil -> "No prompt-like field found on the selected event."
      prompt -> fenced("prompt", prompt, "text")
    end
  end

  defp prompt_text(event) do
    data = Map.get(event, :data) || %{}
    stage_data = field(data, :data) || %{}

    field(data, :prompt) ||
      field(data, :system_prompt) ||
      field(data, :context) ||
      field(data, :conversation_history) ||
      field(stage_data, :prompt) ||
      field(stage_data, :system_prompt) ||
      field(stage_data, :context) ||
      field(stage_data, :conversation_history)
  end

  defp fenced(label, value, language \\ "elixir")

  defp fenced(_label, nil, _language), do: nil

  defp fenced(label, value, language) do
    value =
      cond do
        is_binary(value) -> Redaction.redact_text(value)
        true -> Redaction.inspect_redacted(value)
      end

    """
    #{label}:

    ~~~#{language}
    #{value}
    ~~~
    """
    |> String.trim()
  end

  defp short(value, limit \\ 80)
  defp short(nil, _limit), do: ""

  defp short(value, limit) when is_binary(value),
    do: value |> Redaction.redact_text() |> Helpers.short(limit)

  defp short(value, limit),
    do: value |> Redaction.inspect_redacted(printable_limit: limit) |> Helpers.short(limit)

  defp present?(value), do: value not in [nil, ""]

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
