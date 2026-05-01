defmodule RunicAI.Assistant.RLM.SmokeExpectation do
  @moduledoc """
  Deterministic expectation checks for assistant RLM smoke scenarios.

  The checks are intentionally separate from the model's own scorecard. The
  model-backed run can produce an artifact and an objective scorecard, while the
  smoke expectation layer records whether the observed workflow shape matched
  the scenario pressure we wanted to test.
  """

  alias RunicAI.Assistant.RLM.SmokeScenario

  @type status :: :pass | :review | :fail
  @type check_status :: :pass | :warning | :fail

  @capability_types %{
    artifact_write: ["artifact_writer"],
    document_compare: ["document_compare"],
    hierarchical_reduce: ["blueprint_reduce", "hierarchical_reduce", "llm_leaf"],
    llm_map: ["llm_map"],
    objective_scorecard: ["objective_scorecard", "verification"],
    record_group: ["record_group"],
    record_map: ["record_map"],
    report_composer: ["report_composer"],
    source_discovery: ["source_discovery"],
    source_splitting: ["source_splitter"],
    tabular_parser: ["tabular_parser"]
  }

  @spec evaluate(Path.t(), SmokeScenario.t(), map(), map()) :: map()
  def evaluate(root, %SmokeScenario{} = scenario, summary, result)
      when is_binary(root) and is_map(summary) and is_map(result) do
    artifact = artifact_observation(root, scenario, summary, result)
    sections = section_observation(root, scenario, result, artifact)
    source_cues = source_cue_observation(root, scenario, result, artifact)
    scorecard = scorecard_observation(result, summary)
    quality = quality_observation(root, result, artifact)
    capabilities = capability_observation(scenario, summary)

    checks = [
      artifact_check(scenario, artifact),
      section_check(sections),
      source_cue_check(source_cues),
      scorecard_check(scorecard),
      quality_check(quality),
      capability_check(capabilities)
    ]

    %{
      status: overall_status(checks),
      checks: checks,
      failed_checks: Enum.count(checks, &(&1.status == :fail)),
      warning_checks: Enum.count(checks, &(&1.status == :warning)),
      artifact: artifact,
      sections: sections,
      source_cues: source_cues,
      scorecard: scorecard,
      quality: quality,
      capabilities: capabilities
    }
  end

  @spec markdown(map()) :: String.t()
  def markdown(expectation) when is_map(expectation) do
    rows =
      expectation
      |> Map.get(:checks, [])
      |> Enum.map(fn check ->
        "| #{check.name} | `#{check.status}` | #{cell(check.expected)} | #{cell(check.observed)} | #{cell(check.details)} |"
      end)

    [
      "## Expected Vs Observed",
      "",
      "- Overall status: `#{Map.get(expectation, :status, :unknown)}`",
      "- Failed checks: #{Map.get(expectation, :failed_checks, 0)}",
      "- Warning checks: #{Map.get(expectation, :warning_checks, 0)}",
      "",
      "| Check | Status | Expected | Observed | Details |",
      "| --- | --- | --- | --- | --- |",
      rows
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp artifact_observation(root, scenario, summary, result) do
    path =
      artifact_path(summary) ||
        artifact_path(result) ||
        scorecard_field(result, :artifact_path) ||
        scenario.output

    absolute = Path.join(root, path || "")

    bytes =
      case File.stat(absolute) do
        {:ok, stat} -> stat.size
        {:error, _reason} -> nil
      end

    %{
      path: path,
      exists?: is_binary(path) and File.regular?(absolute),
      bytes: bytes
    }
  end

  defp artifact_path(%{write_result: write_result}) when is_map(write_result),
    do: field(write_result, :path)

  defp artifact_path(%{artifacts: artifacts}) when is_list(artifacts) do
    artifacts
    |> List.last()
    |> case do
      nil -> nil
      artifact -> field(artifact, :path)
    end
  end

  defp artifact_path(_value), do: nil

  defp section_observation(root, scenario, result, artifact) do
    missing =
      case scorecard_field(result, :missing_sections) do
        values when is_list(values) ->
          Enum.map(values, &to_string/1)

        _other ->
          root
          |> artifact_text(artifact.path)
          |> missing_sections(scenario.required_sections)
      end

    %{
      required: scenario.required_sections,
      missing: missing,
      present: scenario.required_sections -- missing
    }
  end

  defp artifact_text(root, path) when is_binary(path) and path != "" do
    root
    |> Path.join(path)
    |> File.read()
    |> case do
      {:ok, text} -> text
      {:error, _reason} -> ""
    end
  end

  defp artifact_text(_root, _path), do: ""

  defp quality_observation(root, result, artifact) do
    case scorecard_field(result, :artifact_quality) do
      quality when is_map(quality) ->
        issues = quality |> field(:issues) |> List.wrap() |> Enum.map(&to_string/1)

        %{
          status:
            if(field(quality, :status) in [:acceptable, "acceptable"], do: :pass, else: :fail),
          issues: issues,
          map_dump_count: field(quality, :map_dump_count) || 0,
          section_count: field(quality, :section_count) || 0,
          unique_section_body_count: field(quality, :unique_section_body_count) || 0
        }

      _other ->
        fallback_quality_observation(root, artifact)
    end
  end

  defp fallback_quality_observation(root, artifact) do
    text = artifact_text(root, artifact.path)
    section_bodies = section_bodies(text)
    map_dump_count = Regex.scan(~r/%\{/, text || "") |> length()
    repeated_sections? = repeated_sections?(section_bodies)

    issues =
      []
      |> maybe_issue(map_dump_count >= 2, "artifact contains Elixir map dumps")
      |> maybe_issue(
        repeated_sections?,
        "multiple sections contain substantially repeated content"
      )
      |> maybe_issue(String.trim(text || "") == "", "artifact text is empty")

    %{
      status: if(issues == [], do: :pass, else: :fail),
      issues: issues,
      map_dump_count: map_dump_count,
      section_count: length(section_bodies),
      unique_section_body_count: unique_body_count(section_bodies)
    }
  end

  defp source_cue_observation(root, scenario, result, artifact) do
    required =
      scorecard_field(result, :required_source_cues) ||
        scenario.source_cues

    missing =
      case scorecard_field(result, :missing_source_cues) do
        values when is_list(values) ->
          Enum.map(values, &to_string/1)

        _other ->
          text = artifact_text(root, artifact.path)
          normalized = normalize_text(text)

          required
          |> List.wrap()
          |> Enum.reject(fn cue -> String.contains?(normalized, normalize_text(cue)) end)
      end

    %{required: required, missing: missing, present: required -- missing}
  end

  defp section_bodies(text) when is_binary(text) do
    ~r/^\#{1,6}\s+.+$/m
    |> Regex.split(text, trim: true)
    |> Enum.drop(1)
    |> Enum.map(&normalize_body/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_body(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp repeated_sections?(section_bodies) when length(section_bodies) < 3, do: false

  defp repeated_sections?(section_bodies) do
    unique_body_count(section_bodies) <= max(1, div(length(section_bodies), 2))
  end

  defp unique_body_count(section_bodies), do: section_bodies |> Enum.uniq() |> length()

  defp maybe_issue(issues, true, issue), do: issues ++ [issue]
  defp maybe_issue(issues, false, _issue), do: issues

  defp missing_sections(text, required_sections) do
    normalized = String.downcase(text || "")

    Enum.reject(required_sections, fn section ->
      String.contains?(normalized, String.downcase(to_string(section)))
    end)
  end

  defp scorecard_observation(result, summary) do
    status =
      scorecard_field(result, :objective_status) ||
        field(summary, :scorecard_status)

    risks =
      scorecard_field(result, :residual_risks) ||
        field(field(summary, :scorecard) || %{}, :residual_risks) ||
        []

    %{status: status, residual_risks: List.wrap(risks)}
  end

  defp scorecard_field(result, key) do
    result
    |> field(:scorecard)
    |> case do
      nil -> nil
      scorecard -> field(scorecard, key)
    end
  end

  defp capability_observation(%SmokeScenario{} = scenario, summary) do
    observed =
      summary
      |> field(:component_types)
      |> List.wrap()
      |> Enum.map(&normalize_type/1)
      |> Enum.reject(&(&1 == ""))

    missing =
      Enum.reject(scenario.expected_workflow_capabilities, fn capability ->
        Enum.any?(capability_types(capability), &(&1 in observed))
      end)

    %{
      expected: scenario.expected_workflow_capabilities,
      observed: observed,
      missing: missing
    }
  end

  defp capability_types(capability) when is_atom(capability),
    do: Map.get(@capability_types, capability, [Atom.to_string(capability)])

  defp capability_types(capability), do: [normalize_type(capability)]

  defp normalize_type(type) when is_atom(type), do: Atom.to_string(type)

  defp normalize_type(type) do
    type
    |> to_string()
    |> String.replace("-", "_")
  end

  defp artifact_check(scenario, artifact) do
    check(
      :artifact,
      if(artifact.exists?, do: :pass, else: :fail),
      scenario.output,
      artifact,
      if(artifact.exists?, do: "artifact exists", else: "artifact is missing")
    )
  end

  defp section_check(%{missing: []} = sections) do
    check(
      :required_sections,
      :pass,
      sections.required,
      sections.present,
      "all required sections found"
    )
  end

  defp section_check(sections) do
    check(
      :required_sections,
      :fail,
      sections.required,
      sections.present,
      "missing sections: #{Enum.join(sections.missing, ", ")}"
    )
  end

  defp source_cue_check(%{required: []} = source_cues) do
    check(
      :source_cues,
      :pass,
      source_cues.required,
      source_cues.present,
      "no source cues required"
    )
  end

  defp source_cue_check(%{missing: []} = source_cues) do
    check(
      :source_cues,
      :pass,
      source_cues.required,
      source_cues.present,
      "all source-specific cues found"
    )
  end

  defp source_cue_check(source_cues) do
    check(
      :source_cues,
      :fail,
      source_cues.required,
      source_cues.present,
      "missing source cues: #{Enum.join(source_cues.missing, ", ")}"
    )
  end

  defp scorecard_check(%{status: status} = scorecard) do
    normalized = normalize_status(status)

    check(
      :objective_scorecard,
      if(normalized == :objective_satisfied, do: :pass, else: :fail),
      :objective_satisfied,
      status || :missing,
      residual_details(scorecard.residual_risks)
    )
  end

  defp quality_check(%{status: :pass} = quality) do
    check(
      :artifact_quality,
      :pass,
      "human-readable, non-repetitive report text",
      quality_observed(quality),
      "artifact quality heuristics passed"
    )
  end

  defp quality_check(quality) do
    check(
      :artifact_quality,
      :fail,
      "human-readable, non-repetitive report text",
      quality_observed(quality),
      Enum.join(quality.issues, "; ")
    )
  end

  defp capability_check(%{missing: []} = capabilities) do
    check(
      :workflow_capabilities,
      :pass,
      capabilities.expected,
      capabilities.observed,
      "workflow shape covered expected capabilities"
    )
  end

  defp capability_check(capabilities) do
    check(
      :workflow_capabilities,
      :warning,
      capabilities.expected,
      capabilities.observed,
      "missing capabilities: #{capabilities.missing |> Enum.map(&to_string/1) |> Enum.join(", ")}"
    )
  end

  defp check(name, status, expected, observed, details) do
    %{name: name, status: status, expected: expected, observed: observed, details: details}
  end

  defp residual_details([]), do: "scorecard satisfied"
  defp residual_details(risks), do: Enum.join(risks, "; ")

  defp quality_observed(quality) do
    %{
      map_dump_count: quality.map_dump_count,
      section_count: quality.section_count,
      unique_section_body_count: quality.unique_section_body_count
    }
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    status
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> status
  end

  defp normalize_status(status), do: status

  defp overall_status(checks) do
    cond do
      Enum.any?(checks, &(&1.status == :fail)) -> :fail
      Enum.any?(checks, &(&1.status == :warning)) -> :review
      true -> :pass
    end
  end

  defp cell(value) when is_binary(value), do: sanitize(value)
  defp cell(value), do: value |> inspect(limit: 20, printable_limit: 500) |> sanitize()

  defp sanitize(value) do
    value
    |> String.replace("\n", "<br>")
    |> String.replace("|", "\\|")
  end

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_map, _key), do: nil
end
