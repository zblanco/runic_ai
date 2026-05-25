defmodule RunicAI.Terminal.EventPresenter do
  @moduledoc """
  Plain text presenter for `RunicAI.Terminal.Event`.

  This module has no side effects. CLI tasks decide where rendered strings are
  written, which keeps terminal presentation separate from backend execution.
  """

  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.GraphPresenter

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
      "  persistence: #{value(opts, :persistence, :sqlite)}",
      sqlite_line(opts),
      header_line("async", value(opts, :async, nil)),
      header_line("max concurrency", value(opts, :max_concurrency, nil)),
      header_line("LLM map concurrency", value(opts, :max_llm_map_concurrency, nil)),
      header_line("LLM map calls", value(opts, :max_llm_map_calls, nil)),
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
      detail_lines(event, detail_mode, opts)
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
      review_decision_line(request)
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

  defp detail_lines(_event, :hidden, _opts), do: []

  defp detail_lines(%Event{} = event, :collapsed, _opts) do
    case mermaid_tool_output(event) do
      nil -> collapsed_detail(event.detail)
      output -> mermaid_tool_output_lines(output)
    end
  end

  defp detail_lines(%Event{kind: :rlm_plan, phase: :proposed, data: data}, :expanded, opts) do
    proposal = data["proposal"] || data[:proposal] || %{}
    render_graph_detail(proposal, opts)
  end

  defp detail_lines(%Event{kind: :rlm_plan, phase: :compiled, data: data}, :expanded, opts) do
    graph = data["compiled"] || data[:compiled] || %{}

    case render_graph_detail(graph, opts) do
      [] -> expanded_detail(nil, data)
      lines -> lines
    end
  end

  defp detail_lines(%Event{kind: :summary, phase: :scorecard, data: data}, :expanded, _opts) do
    scorecard = data["scorecard"] || data[:scorecard] || %{}
    risks = scorecard["residual_risks"] || scorecard[:residual_risks] || []
    changed = scorecard["changed_files"] || scorecard[:changed_files] || []

    [
      maybe_line("  changed", Enum.join(changed, ", ")),
      maybe_line("  risks", Enum.join(risks, "; "))
    ]
  end

  defp detail_lines(%Event{} = event, :expanded, _opts) do
    case mermaid_tool_output(event) do
      nil -> expanded_detail(event.detail, event.data)
      output -> mermaid_tool_output_lines(output)
    end
  end

  defp detail_lines(_event, _mode, _opts), do: []

  defp collapsed_detail(detail) when is_binary(detail) and detail != "" do
    ["  #{single_line(detail)}"]
  end

  defp collapsed_detail(_detail), do: []

  defp expanded_detail(detail, data) do
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

  defp render_graph_detail(graph, opts) do
    graph = graph["graph_summary"] || graph[:graph_summary] || graph

    nodes =
      graph["nodes"] || graph[:nodes] || graph["components"] || graph[:components] ||
        get_in(graph, ["runic", "native_nodes"]) ||
        get_in(graph, [:runic, :native_nodes]) ||
        []

    if nodes == [] do
      []
    else
      graph
      |> GraphPresenter.render_lines(
        mode: Keyword.get(opts, :graph, :text),
        color: Keyword.get(opts, :color, :auto)
      )
      |> Enum.map(&("  " <> &1))
    end
  end

  defp render_standard_final_report(result) do
    summary = Map.get(result, :summary, %{})

    [
      "",
      "Final report",
      "  status: #{Map.get(result, :status)}",
      "  session: #{Map.get(result, :session_id)}",
      maybe_line("  agent status", summary[:status] || summary["status"]),
      maybe_list("  changed files", summary[:changed_files] || summary["changed_files"]),
      maybe_list("  tools used", summary[:tools_used] || summary["tools_used"]),
      rendered_diagram_report_lines(summary),
      maybe_line("  objective", summary[:objective_status] || summary["objective_status"]),
      maybe_line("  error", summary[:last_error] || summary["last_error"]),
      maybe_list("  risks", summary[:risks] || summary["risks"]),
      maybe_line("  reply", summary[:reply] || summary["reply"])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_rlm_final_report(result) do
    scorecard = Map.get(result, :scorecard) || Map.get(result, "scorecard") || %{}
    changed = field(scorecard, :changed_files) || []
    risks = field(scorecard, :residual_risks) || []

    [
      "",
      "Final report",
      "  status: #{Map.get(result, :status)}",
      "  run: #{Map.get(result, :session_id) || Map.get(result, :run_id)}",
      maybe_line("  objective", field(scorecard, :objective_status)),
      maybe_list("  changed files", changed),
      maybe_list("  risks", risks),
      maybe_line("  objective resume", objective_resume_limit_report(result)),
      maybe_line("  persistence", Map.get(result, :persistence_ref))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp objective_resume_limit_report(result) do
    if Map.get(result, :objective_auto_resume_exhausted?) do
      attempts = Map.get(result, :objective_resume_attempts)
      limit = Map.get(result, :objective_resume_limit)
      kind = Map.get(result, :objective_resume_kind)

      "limit reached after #{attempts}/#{limit} automatic #{kind} resumes"
    end
  end

  defp render_assistant_final_report(result) do
    scorecard = Map.get(result, :scorecard) || Map.get(result, "scorecard") || %{}
    artifacts = Map.get(result, :artifacts) || Map.get(result, "artifacts") || []
    risks = field(scorecard, :residual_risks) || []

    [
      "",
      "Final report",
      "  status: #{Map.get(result, :status)}",
      "  run: #{Map.get(result, :session_id) || Map.get(result, :run_id)}",
      maybe_line("  objective", field(scorecard, :objective_status)),
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

  defp mermaid_tool_output(%Event{data: data}) when is_map(data) do
    data
    |> field(:output)
    |> unwrap_tool_output()
    |> case do
      output when is_map(output) ->
        command = field(output, :command)

        if is_binary(command) and String.starts_with?(command, "mmdflux") do
          output
        end

      _other ->
        nil
    end
  end

  defp mermaid_tool_output(_event), do: nil

  defp unwrap_tool_output(output) when is_map(output) do
    nested = field(output, :output)

    if is_map(nested) do
      nested
    else
      output
    end
  end

  defp unwrap_tool_output(output), do: output

  defp mermaid_tool_output_lines(output) do
    rendered = field(output, :rendered)

    [
      maybe_line("  mmdflux", field(output, :status)),
      maybe_line("  source", mermaid_source_label(output)),
      maybe_line("  error", field(output, :error)),
      rendered_header(rendered),
      rendered && indent_block(rendered, "    ")
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp rendered_diagram_report_lines(summary) do
    diagrams = summary[:rendered_diagrams] || summary["rendered_diagrams"] || []

    case diagrams do
      [] ->
        nil

      diagrams ->
        [
          "  rendered diagrams:"
          | diagrams
            |> Enum.with_index(1)
            |> Enum.flat_map(fn {diagram, index} ->
              rendered_diagram_lines(diagram, index)
            end)
        ]
    end
  end

  defp rendered_diagram_lines(diagram, index) do
    rendered = field(diagram, :rendered)

    [
      "    #{index}. #{rendered_diagram_label(diagram)}",
      maybe_line("       status", field(diagram, :status)),
      maybe_line("       error", field(diagram, :error)),
      rendered && indent_block(rendered, "       ")
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp rendered_diagram_label(diagram) do
    [
      field(diagram, :path),
      field(diagram, :heading) && "heading #{field(diagram, :heading)}",
      field(diagram, :diagram_index) && "diagram #{field(diagram, :diagram_index)}",
      field(diagram, :line_start) && "line #{field(diagram, :line_start)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> "inline Mermaid source"
      label -> label
    end
  end

  defp mermaid_source_label(output) do
    [
      field(output, :path),
      field(output, :heading) && "heading #{field(output, :heading)}",
      field(output, :diagram_index) && "diagram #{field(output, :diagram_index)}",
      field(output, :line_start) && "line #{field(output, :line_start)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp rendered_header(rendered) when is_binary(rendered) and rendered != "", do: "  rendered:"
  defp rendered_header(_rendered), do: nil

  defp indent_block(text, prefix) do
    text
    |> String.trim_trailing()
    |> String.split("\n", trim: false)
    |> Enum.map(&(prefix <> &1))
  end

  defp jsonl_line(%{jsonl_path: nil}), do: nil
  defp jsonl_line(%{jsonl_path: path}), do: "  jsonl: #{path}"
  defp jsonl_line(_opts), do: nil

  defp sqlite_line(%{sqlite_path: nil}), do: nil
  defp sqlite_line(%{sqlite_path: path}), do: "  sqlite: #{path}"
  defp sqlite_line(_opts), do: nil

  defp header_line(_label, nil), do: nil
  defp header_line(label, value), do: "  #{label}: #{value}"

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

  defp review_decision_line(%ReviewRequest{options: options}) do
    [
      if(:approve in options, do: "[a] approve"),
      if(:reject in options, do: "[d] deny"),
      if(:edit in options, do: "[r] rewrite"),
      if(:cancel in options, do: "[s] final stop")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("  ")
  end

  defp value(opts, key, default) do
    case Map.fetch(opts, key) do
      {:ok, value} when not is_nil(value) ->
        value

      _other ->
        case Map.fetch(opts, Atom.to_string(key)) do
          {:ok, value} when not is_nil(value) -> value
          _other -> default
        end
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

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
