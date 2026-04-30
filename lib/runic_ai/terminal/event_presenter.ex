defmodule RunicAI.Terminal.EventPresenter do
  @moduledoc """
  Plain text presenter for `RunicAI.Terminal.Event`.

  This module has no side effects. CLI tasks decide where rendered strings are
  written, which keeps terminal presentation separate from backend execution.
  """

  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.Event

  @type detail_mode :: :hidden | :collapsed | :expanded

  @spec render_header(map() | keyword()) :: String.t()
  def render_header(opts) do
    opts = Map.new(opts)

    [
      "RunicAI agent",
      "  session: #{value(opts, :session_id, "auto")}",
      "  workspace: #{value(opts, :cwd, File.cwd!())}",
      "  agent: #{value(opts, :agent, :standard)}",
      "  model: #{value(opts, :model, "default")}",
      "  client: #{value(opts, :client, "default")}",
      "  detail: #{value(opts, :detail, :collapsed)}",
      jsonl_line(opts)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @spec render_event(Event.t(), keyword()) :: String.t()
  def render_event(%Event{} = event, opts \\ []) do
    detail_mode = Keyword.get(opts, :detail, :collapsed)

    [
      summary_line(event),
      detail_lines(event, detail_mode)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @spec render_final_report(map(), keyword()) :: String.t()
  def render_final_report(result, opts \\ []) when is_map(result) do
    agent = Map.get(result, :agent, Keyword.get(opts, :agent, :standard))

    case agent do
      :assistant -> render_assistant_final_report(result)
      :rlm -> render_rlm_final_report(result)
      _other -> render_standard_final_report(result)
    end
  end

  @spec render_review_prompt(ReviewRequest.t()) :: String.t()
  def render_review_prompt(%ReviewRequest{} = request) do
    [
      "",
      "Review required: #{request.kind}",
      maybe_line("Checkpoint", request.checkpoint),
      maybe_line("Reason", request.details[:reason] || request.details["reason"]),
      maybe_line("Tool", request.details[:tool_name] || request.details["tool_name"]),
      maybe_line("Path", request.details[:path] || request.details["path"]),
      maybe_line("Command", command_preview(request.details)),
      "",
      "[a] approve  [d] deny  [s] final stop"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp summary_line(%Event{} = event) do
    time =
      event.at
      |> DateTime.to_time()
      |> Time.truncate(:second)
      |> Time.to_iso8601()

    phase =
      case event.phase do
        nil -> Atom.to_string(event.kind)
        phase -> "#{event.kind}/#{phase}"
      end

    "[#{time}] #{String.upcase(Atom.to_string(event.status))} #{phase} #{event.title}"
  end

  defp detail_lines(_event, :hidden), do: []

  defp detail_lines(%Event{detail: detail}, :collapsed) when is_binary(detail) and detail != "" do
    ["  #{single_line(detail)}"]
  end

  defp detail_lines(%Event{kind: :rlm_plan, phase: :proposed, data: data}, :expanded) do
    proposal = data["proposal"] || data[:proposal] || %{}

    [
      "  objective: #{proposal["objective"] || proposal[:objective]}",
      proposal_nodes(proposal)
    ]
  end

  defp detail_lines(%Event{kind: :summary, phase: :scorecard, data: data}, :expanded) do
    scorecard = data["scorecard"] || data[:scorecard] || %{}
    risks = scorecard["residual_risks"] || scorecard[:residual_risks] || []
    changed = scorecard["changed_files"] || scorecard[:changed_files] || []

    [
      maybe_line("  changed", Enum.join(changed, ", ")),
      maybe_line("  risks", Enum.join(risks, "; "))
    ]
  end

  defp detail_lines(%Event{detail: detail, data: data}, :expanded) do
    detail = if is_binary(detail) and detail != "", do: ["  #{detail}"], else: []

    data_lines =
      data
      |> compact_data()
      |> case do
        nil -> []
        rendered -> ["  data: #{rendered}"]
      end

    detail ++ data_lines
  end

  defp detail_lines(_event, _mode), do: []

  defp proposal_nodes(proposal) do
    proposal
    |> Map.get("nodes", Map.get(proposal, :nodes, []))
    |> Enum.map(fn node ->
      id = node["id"] || node[:id]
      kind = node["kind"] || node[:kind] || node["type"] || node[:type]
      deps = node["dependencies"] || node[:dependencies] || []
      dep_text = if deps == [], do: "root", else: Enum.join(deps, ", ")
      "  [#{id}] #{kind} <- #{dep_text}"
    end)
  end

  defp render_standard_final_report(result) do
    summary = Map.get(result, :summary, %{})

    [
      "",
      "Final report",
      "  status: #{Map.get(result, :status)}",
      "  session: #{Map.get(result, :session_id)}",
      maybe_list("  changed files", summary[:changed_files] || summary["changed_files"]),
      maybe_list("  tools used", summary[:tools_used] || summary["tools_used"]),
      maybe_line("  objective", summary[:objective_status] || summary["objective_status"]),
      maybe_list("  risks", summary[:risks] || summary["risks"]),
      maybe_line("  reply", summary[:reply] || summary["reply"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_rlm_final_report(result) do
    scorecard = Map.get(result, :scorecard) || Map.get(result, "scorecard") || %{}
    changed = scorecard[:changed_files] || scorecard["changed_files"] || []
    risks = scorecard[:residual_risks] || scorecard["residual_risks"] || []

    [
      "",
      "Final report",
      "  status: #{Map.get(result, :status)}",
      "  run: #{Map.get(result, :session_id) || Map.get(result, :run_id)}",
      maybe_line("  objective", scorecard[:objective_status] || scorecard["objective_status"]),
      maybe_list("  changed files", changed),
      maybe_list("  risks", risks),
      maybe_line("  persistence", Map.get(result, :persistence_ref))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_assistant_final_report(result) do
    scorecard = Map.get(result, :scorecard) || Map.get(result, "scorecard") || %{}
    artifacts = Map.get(result, :artifacts) || Map.get(result, "artifacts") || []
    risks = scorecard[:residual_risks] || scorecard["residual_risks"] || []

    [
      "",
      "Final report",
      "  status: #{Map.get(result, :status)}",
      "  run: #{Map.get(result, :session_id) || Map.get(result, :run_id)}",
      maybe_line("  objective", scorecard[:objective_status] || scorecard["objective_status"]),
      maybe_list("  artifacts", artifact_paths(artifacts)),
      maybe_list("  risks", risks)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp compact_data(data) when map_size(data) == 0, do: nil

  defp compact_data(data) do
    data
    |> Map.take([
      "trace_kind",
      "stage",
      "status",
      "output",
      :trace_kind,
      :stage,
      :status,
      :output
    ])
    |> case do
      compact when map_size(compact) == 0 -> nil
      compact -> inspect(compact, limit: 8, printable_limit: 240)
    end
  end

  defp jsonl_line(%{jsonl_path: nil}), do: nil
  defp jsonl_line(%{jsonl_path: path}), do: "  jsonl: #{path}"
  defp jsonl_line(_opts), do: nil

  defp maybe_line(_label, nil), do: nil
  defp maybe_line(_label, ""), do: nil
  defp maybe_line(label, value), do: "#{label}: #{value}"

  defp maybe_list(_label, nil), do: nil
  defp maybe_list(_label, []), do: nil
  defp maybe_list(label, values), do: "#{label}: #{Enum.join(values, ", ")}"

  defp artifact_paths(artifacts) do
    artifacts
    |> List.wrap()
    |> Enum.map(fn artifact ->
      if is_map(artifact), do: artifact[:path] || artifact["path"], else: nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp command_preview(details) when is_map(details) do
    details[:command] || details["command"] ||
      case details[:argv] || details["argv"] do
        argv when is_list(argv) -> Enum.join(argv, " ")
        _other -> nil
      end
  end

  defp command_preview(_details), do: nil

  defp value(opts, key, default),
    do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key)) || default

  defp single_line(text) do
    text
    |> String.replace("\n", " ")
    |> truncate(180)
  end

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
