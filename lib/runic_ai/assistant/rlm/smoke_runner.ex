defmodule RunicAI.Assistant.RLM.SmokeRunner do
  @moduledoc """
  Runs assistant RLM smoke scenarios and writes comparable `tmp` reports.
  """

  alias RunicAI.Assistant.RLM.Agent
  alias RunicAI.Assistant.RLM.SmokeExpectation
  alias RunicAI.Assistant.RLM.SmokeScenario
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.TraceSummary

  @spec run_scenario(Path.t(), atom() | String.t() | SmokeScenario.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run_scenario(root, scenario_or_id, opts \\ []) do
    with {:ok, scenario} <- scenario_from_input(scenario_or_id),
         {:ok, workspace} <- workspace(root, opts) do
      SmokeScenario.ensure_fixtures!(workspace.root)

      {:ok, event_agent} = Elixir.Agent.start_link(fn -> [] end)

      agent_opts =
        [
          input_paths: scenario.inputs,
          output_path: scenario.output,
          required_sections: scenario.required_sections,
          required_source_cues: scenario.source_cues,
          require_artifact_quality?: Keyword.get(opts, :require_artifact_quality?, true),
          write_policy: Keyword.get(opts, :write_policy, :workspace_review),
          max_generated_function_tier: Keyword.get(opts, :max_generated_function_tier, :tier1),
          model: Keyword.get(opts, :model),
          client: Keyword.get(opts, :client),
          proposal_strategy: Keyword.get(opts, :proposal_strategy),
          fallback?: Keyword.get(opts, :fallback?, true),
          event_sink: fn event -> Elixir.Agent.update(event_agent, &(&1 ++ [event])) end
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case Agent.run(workspace, scenario.objective, agent_opts) do
        {:ok, result} ->
          events = Elixir.Agent.get(event_agent, & &1)
          Elixir.Agent.stop(event_agent)
          summary = TraceSummary.summarize(result, events: events)
          expectation = SmokeExpectation.evaluate(workspace.root, scenario, summary, result)
          report_path = report_path(scenario, opts)

          run_path =
            maybe_persist_run!(workspace.root, scenario, summary, result, expectation, opts)

          matrix_entry = matrix_entry(scenario, summary, expectation, report_path, run_path)

          if Keyword.get(opts, :write_report?, true) do
            write_report!(
              workspace.root,
              report_path,
              scenario,
              summary,
              result,
              expectation,
              opts
            )
          end

          {:ok,
           %{
             scenario: scenario,
             result: result,
             events: events,
             summary: summary,
             expectation: expectation,
             report_path: report_path,
             run_path: run_path,
             matrix_entry: matrix_entry
           }}

        {:error, %Error{} = error} ->
          Elixir.Agent.stop(event_agent)
          {:error, error}
      end
    end
  end

  @spec run_matrix(Path.t(), [atom() | String.t()] | nil, keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run_matrix(root, ids \\ nil, opts \\ []) do
    scenarios =
      case ids do
        nil ->
          SmokeScenario.all()

        ids ->
          Enum.map(ids, fn id ->
            {:ok, scenario} = SmokeScenario.get(id)
            scenario
          end)
      end

    results =
      scenarios
      |> Enum.reduce_while({:ok, []}, fn scenario, {:ok, acc} ->
        case run_scenario(root, scenario, opts) do
          {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)

    with {:ok, results} <- results,
         {:ok, workspace} <- workspace(root, opts) do
      matrix_path = Keyword.get(opts, :matrix_path, default_matrix_path(opts))
      write_matrix!(workspace.root, matrix_path, results)
      {:ok, %{results: results, matrix_path: matrix_path}}
    end
  end

  @spec compare_matrices(Path.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def compare_matrices(root, opts \\ []) do
    with {:ok, workspace} <- workspace(root, opts),
         {:ok, fallback} <-
           read_matrix(
             workspace.root,
             Keyword.get(opts, :fallback_matrix_path, fallback_matrix_path())
           ),
         {:ok, dynamic} <-
           read_matrix(
             workspace.root,
             Keyword.get(opts, :dynamic_matrix_path, dynamic_matrix_path())
           ) do
      comparison_path =
        Keyword.get(
          opts,
          :comparison_path,
          "tmp/assistant_smoke/reports/assistant-rlm-smoke-strategy-comparison.md"
        )

      write_comparison!(workspace.root, comparison_path, fallback, dynamic)
      {:ok, %{comparison_path: comparison_path, fallback: fallback, dynamic: dynamic}}
    end
  end

  defp scenario_from_input(%SmokeScenario{} = scenario), do: {:ok, scenario}

  defp scenario_from_input(id) do
    case SmokeScenario.get(id) do
      {:ok, scenario} ->
        {:ok, scenario}

      :error ->
        {:error,
         Error.validation("unknown assistant RLM smoke scenario",
           source: __MODULE__,
           details: %{id: id}
         )}
    end
  end

  defp workspace(%Workspace{} = workspace, _opts), do: Workspace.validate(workspace)

  defp workspace(root, opts) do
    Workspace.new(
      root: root,
      path_policy:
        PathPolicy.new!(
          hidden_policy: :allow,
          allowed_write_roots: Keyword.get(opts, :allowed_write_roots, ["tmp"]),
          max_file_bytes: Keyword.get(opts, :max_file_bytes, 5_242_880)
        )
    )
  end

  defp report_path(scenario, opts) do
    Keyword.get(opts, :report_path, default_report_path(scenario, opts))
  end

  defp default_report_path(scenario, opts) do
    case Keyword.get(opts, :run_label) do
      nil ->
        "tmp/assistant_smoke/reports/assistant-rlm-smoke-#{scenario.id}.md"

      "" ->
        "tmp/assistant_smoke/reports/assistant-rlm-smoke-#{scenario.id}.md"

      label ->
        "tmp/assistant_smoke/reports/assistant-rlm-smoke-#{safe_label(label)}-#{scenario.id}.md"
    end
  end

  defp default_matrix_path(opts) do
    case Keyword.get(opts, :run_label) do
      nil -> "tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix.md"
      "" -> "tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix.md"
      label -> "tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix-#{safe_label(label)}.md"
    end
  end

  defp fallback_matrix_path,
    do: "tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix-fallback.md"

  defp dynamic_matrix_path,
    do: "tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix-dynamic.md"

  defp run_path(scenario, opts) do
    Keyword.get(opts, :run_path, default_run_path(scenario, opts))
  end

  defp default_run_path(scenario, opts) do
    case Keyword.get(opts, :run_label) do
      nil ->
        "tmp/assistant_smoke/runs/assistant-rlm-smoke-#{scenario.id}.json"

      "" ->
        "tmp/assistant_smoke/runs/assistant-rlm-smoke-#{scenario.id}.json"

      label ->
        "tmp/assistant_smoke/runs/assistant-rlm-smoke-#{safe_label(label)}-#{scenario.id}.json"
    end
  end

  defp write_report!(root, path, scenario, summary, result, expectation, opts) do
    absolute = Path.join(root, path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, report_markdown(scenario, summary, result, expectation, opts))
  end

  defp maybe_persist_run!(root, scenario, summary, result, expectation, opts) do
    if Keyword.get(opts, :persist_run?, true) do
      path = run_path(scenario, opts)
      absolute = Path.join(root, path)
      File.mkdir_p!(Path.dirname(absolute))

      File.write!(
        absolute,
        Jason.encode!(run_payload(scenario, summary, result, expectation, opts), pretty: true)
      )

      path
    end
  end

  defp run_payload(scenario, summary, result, expectation, opts) do
    %{
      scenario: %{
        id: scenario.id,
        objective: scenario.objective,
        inputs: scenario.inputs,
        output: scenario.output,
        required_sections: scenario.required_sections,
        required_source_cues: scenario.source_cues,
        expected_workflow_capabilities: scenario.expected_workflow_capabilities
      },
      run: %{
        label: Keyword.get(opts, :run_label, "default"),
        proposal_strategy: Keyword.get(opts, :proposal_strategy, :dynamic),
        status: result.status,
        run_id: result.run_id
      },
      graph_summary: get(result.compiled || %{}, :graph_summary, %{}),
      blueprint: json_safe(result.blueprint),
      validation_report: json_safe(result.validation_report),
      scorecard: json_safe(result.scorecard),
      expectation: json_safe(expectation),
      trace_summary: json_safe(summary),
      artifacts: json_safe(result.artifacts || []),
      repair_history: json_safe(result.repair_history || []),
      intermediate_outputs: intermediate_outputs(result.context)
    }
  end

  defp write_matrix!(root, path, results) do
    absolute = Path.join(root, path)
    File.mkdir_p!(Path.dirname(absolute))

    rows =
      results
      |> Enum.map(& &1.matrix_entry)
      |> Enum.map(fn entry ->
        "| `#{entry.id}` | `#{entry.expectation_status}` | `#{entry.status}` | #{entry.nodes} | #{Enum.join(entry.component_types, ", ")} | #{missing_capabilities(entry)} | `#{entry.artifact}` | #{entry.repairs} | `#{entry.report_path}` | `#{entry.run_path || ""}` |"
      end)

    content =
      [
        "# Assistant RLM Smoke Matrix",
        "",
        "| Scenario | Expectation | Scorecard | Nodes | Component Types | Capability Gaps | Artifact | Repairs | Report | Run Details |",
        "| --- | --- | --- | ---: | --- | --- | --- | ---: | --- | --- |",
        rows
      ]
      |> List.flatten()
      |> Enum.join("\n")

    File.write!(absolute, content <> "\n")
  end

  defp read_matrix(root, path) do
    root
    |> Path.join(path)
    |> File.read()
    |> case do
      {:ok, content} ->
        {:ok, %{path: path, rows: parse_matrix_rows(content)}}

      {:error, reason} ->
        {:error,
         Error.validation("assistant smoke matrix could not be read",
           source: __MODULE__,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp parse_matrix_rows(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| `"))
    |> Enum.map(&parse_matrix_row/1)
    |> Map.new(&{&1.id, &1})
  end

  defp parse_matrix_row(row) do
    cells =
      row
      |> String.trim()
      |> String.trim_leading("|")
      |> String.trim_trailing("|")
      |> String.split("|")
      |> Enum.map(&String.trim/1)

    %{
      id: uncode(Enum.at(cells, 0, "")),
      expectation: uncode(Enum.at(cells, 1, "")),
      scorecard: uncode(Enum.at(cells, 2, "")),
      nodes: parse_integer(Enum.at(cells, 3, "0")),
      component_types: Enum.at(cells, 4, ""),
      capability_gaps: Enum.at(cells, 5, ""),
      artifact: uncode(Enum.at(cells, 6, "")),
      repairs: parse_integer(Enum.at(cells, 7, "0")),
      report_path: uncode(Enum.at(cells, 8, "")),
      run_path: uncode(Enum.at(cells, 9, ""))
    }
  end

  defp write_comparison!(root, path, fallback, dynamic) do
    absolute = Path.join(root, path)
    File.mkdir_p!(Path.dirname(absolute))

    ids =
      (Map.keys(fallback.rows) ++ Map.keys(dynamic.rows))
      |> Enum.uniq()
      |> Enum.sort()

    rows =
      Enum.map(ids, fn id ->
        fallback_row = Map.get(fallback.rows, id, %{})
        dynamic_row = Map.get(dynamic.rows, id, %{})

        "| `#{id}` | `#{comparison_field(fallback_row, :expectation)}` | `#{comparison_field(dynamic_row, :expectation)}` | `#{comparison_field(fallback_row, :scorecard)}` | `#{comparison_field(dynamic_row, :scorecard)}` | #{comparison_field(fallback_row, :nodes)} | #{comparison_field(dynamic_row, :nodes)} | #{comparison_field(fallback_row, :repairs)} | #{comparison_field(dynamic_row, :repairs)} | #{comparison_delta(fallback_row, dynamic_row)} |"
      end)

    content =
      [
        "# Assistant RLM Strategy Comparison",
        "",
        "- Fallback matrix: `#{fallback.path}`",
        "- Dynamic matrix: `#{dynamic.path}`",
        "",
        "| Scenario | Fallback Expectation | Dynamic Expectation | Fallback Scorecard | Dynamic Scorecard | Fallback Nodes | Dynamic Nodes | Fallback Repairs | Dynamic Repairs | Delta |",
        "| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |",
        rows
      ]
      |> List.flatten()
      |> Enum.join("\n")

    File.write!(absolute, content <> "\n")
  end

  defp report_markdown(scenario, summary, result, expectation, opts) do
    [
      "# Assistant RLM Smoke: #{scenario.id}",
      "",
      "## Scenario",
      "",
      "- Run label: `#{Keyword.get(opts, :run_label, "default")}`",
      "- Proposal strategy: `#{Keyword.get(opts, :proposal_strategy, :dynamic)}`",
      "- Objective: #{scenario.objective}",
      "- Inputs: #{inline_code(scenario.inputs)}",
      "- Output: `#{scenario.output}`",
      "- Required sections: #{inline_code(scenario.required_sections)}",
      "- Required source cues: #{inline_code(scenario.source_cues)}",
      "- Expected capabilities: #{inline_code(scenario.expected_workflow_capabilities)}",
      "",
      "## Trace Summary",
      "",
      TraceSummary.markdown(summary, title: "Trace Summary"),
      "",
      SmokeExpectation.markdown(expectation),
      "",
      "## Manual Review Checklist",
      "",
      Enum.map(scenario.manual_review_checklist, &"- [ ] #{&1}"),
      "",
      "## Result Snapshot",
      "",
      "```elixir",
      inspect(Map.take(result, [:status, :artifacts, :repair_history, :scorecard]),
        pretty: true,
        limit: 50
      ),
      "```"
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp matrix_entry(scenario, summary, expectation, report_path, run_path) do
    %{
      id: scenario.id,
      status: summary.scorecard_status || "unknown",
      expectation_status: expectation.status,
      missing_capabilities: get(expectation.capabilities || %{}, :missing, []),
      failed_checks: expectation.failed_checks || 0,
      warning_checks: expectation.warning_checks || 0,
      nodes: summary.nodes_generated || 0,
      component_types: summary.component_types || [],
      artifact: get(summary.write_result || %{}, :path, scenario.output),
      repairs: length(summary.repair_history || []),
      report_path: report_path,
      run_path: run_path
    }
  end

  defp intermediate_outputs(nil), do: %{}

  defp intermediate_outputs(context) when is_map(context) do
    context
    |> get(:outputs, %{})
    |> Enum.map(fn {id, output} -> {id, output_summary(output)} end)
    |> Map.new()
    |> json_safe()
  end

  defp output_summary(value) when is_binary(value) do
    %{type: "text", length: String.length(value), preview: preview(value)}
  end

  defp output_summary(value) when is_list(value) do
    %{type: "list", count: length(value), preview: preview(value)}
  end

  defp output_summary(value) when is_map(value) do
    %{
      type: "map",
      keys: value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      preview: preview(value)
    }
  end

  defp output_summary(value), do: %{type: "term", preview: preview(value)}

  defp inline_code(values), do: values |> List.wrap() |> Enum.map(&"`#{&1}`") |> Enum.join(", ")

  defp missing_capabilities(%{missing_capabilities: []}), do: "none"

  defp missing_capabilities(%{missing_capabilities: capabilities}) do
    capabilities
    |> Enum.map(&"`#{&1}`")
    |> Enum.join(", ")
  end

  defp comparison_field(row, key), do: Map.get(row, key, "missing")

  defp comparison_delta(fallback_row, dynamic_row) do
    cond do
      map_size(fallback_row) == 0 ->
        "missing fallback run"

      map_size(dynamic_row) == 0 ->
        "missing dynamic run"

      comparison_field(fallback_row, :expectation) != comparison_field(dynamic_row, :expectation) ->
        "expectation changed"

      comparison_field(fallback_row, :scorecard) != comparison_field(dynamic_row, :scorecard) ->
        "scorecard changed"

      comparison_field(fallback_row, :repairs) != comparison_field(dynamic_row, :repairs) ->
        "repair count changed"

      true ->
        "same status"
    end
  end

  defp uncode(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
  end

  defp parse_integer(value) do
    value
    |> uncode()
    |> Integer.parse()
    |> case do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  defp safe_label(label) do
    label
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "run"
      value -> value
    end
  end

  defp json_safe(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> json_safe()
  end

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe(value), do: inspect(value, limit: 20, printable_limit: 2_000)

  defp preview(value) when is_binary(value) do
    if String.length(value) > 500, do: String.slice(value, 0, 500) <> "...", else: value
  end

  defp preview(value), do: inspect(value, limit: 8, printable_limit: 500)

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
