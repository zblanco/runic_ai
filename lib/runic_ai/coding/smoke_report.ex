defmodule RunicAI.Coding.SmokeReport do
  @moduledoc """
  Compact Markdown reports for coding-agent smoke and regression artifacts.

  The input can be a live atom-keyed summary or a decoded JSON map with string
  keys. Reports intentionally separate model trajectory, tool evidence,
  objective evidence, independent verification, and residual risk so overclaims
  are visible without replaying the original process.
  """

  @spec compact(map(), keyword()) :: String.t()
  def compact(summary, opts \\ []) when is_map(summary) and is_list(opts) do
    title = Keyword.get(opts, :title, default_title(summary))
    comparison = Keyword.get(opts, :compare_with)

    [
      "# #{title}",
      "",
      status_block(summary),
      "",
      overclaim_block(summary),
      "",
      "## Model Trajectory",
      model_trajectory(summary),
      "",
      "## Tool Evidence",
      tool_evidence(summary),
      "",
      "## Objective Scorecard",
      objective_scorecard(summary),
      "",
      "## Independent Verification",
      independent_verification(summary),
      "",
      "## Residual Risk",
      residual_risk(summary),
      "",
      comparison_section(summary, comparison)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  @spec overclaim?(map()) :: boolean()
  def overclaim?(summary) when is_map(summary) do
    completion_claim?(reply(summary)) and not verified_complete?(summary)
  end

  @spec load_json!(Path.t()) :: map()
  def load_json!(path) when is_binary(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp default_title(summary) do
    agent = field(summary, :agent) || field(summary, :agent_type) || "Coding Agent"
    "#{agent} Smoke Report"
  end

  defp status_block(summary) do
    """
    Status: #{inspect_field(summary, :status)}
    Objective status: #{inspect(objective_status(summary))}
    Independent success: #{inspect(independent_success?(summary))}
    """
    |> String.trim()
  end

  defp overclaim_block(summary) do
    if overclaim?(summary) do
      """
      Overclaim warning: the model reply appears to claim completion, but the
      objective scorecard or independent verifier does not show completion.
      """
      |> String.trim()
    end
  end

  defp model_trajectory(summary) do
    trace = field(summary, :trace) || field(summary, :trajectory) || []
    agent_summary = agent_summary(summary)
    tools = field(agent_summary, :tools_used) || field(summary, :tools_used) || []

    [
      "- Model: `#{field(summary, :model) || "unknown"}`",
      "- Tools used: #{inline_list(tools)}",
      "- Trace events: #{trace_count(trace)}",
      maybe_bullet("Final reply", truncate(reply(summary), 500))
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp tool_evidence(summary) do
    agent_summary = agent_summary(summary)
    changed = field(agent_summary, :changed_files) || field(summary, :changed_files) || []
    verifications = field(agent_summary, :verifications) || field(summary, :verifications) || []
    repairs = field(agent_summary, :repair_attempts) || field(summary, :repair_attempts) || []

    [
      "- Changed files: #{inline_list(changed)}",
      "- Verification observations: #{length(List.wrap(verifications))}",
      "- Repair attempts: #{length(List.wrap(repairs))}",
      evidence_table(verifications)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp objective_scorecard(summary) do
    agent_summary = agent_summary(summary)
    scorecard = field(agent_summary, :objective_scorecard) || field(summary, :objective_scorecard)
    status = objective_status(summary)

    [
      "- Status: #{inspect(status)}",
      "- Acceptance checks: #{length(List.wrap(field(scorecard || %{}, :acceptance_results)))}",
      "- Blocking checks: #{length(List.wrap(field(scorecard || %{}, :blocking_acceptance)))}",
      scorecard_failures(scorecard)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp independent_verification(summary) do
    checks = field(summary, :independent_checks) || %{}

    if checks == %{} do
      "- No independent verifier artifact was attached."
    else
      checks
      |> Enum.map(fn {name, value} ->
        "- `#{name}`: #{check_status(value)}"
      end)
      |> Enum.join("\n")
    end
  end

  defp residual_risk(summary) do
    agent_summary = agent_summary(summary)
    risks = field(agent_summary, :risks) || field(summary, :risks) || []

    cond do
      overclaim?(summary) ->
        "- Model overclaim risk remains.\n#{risk_lines(risks)}"

      risks == [] ->
        "- No residual risks reported."

      true ->
        risk_lines(risks)
    end
  end

  defp comparison_section(_summary, nil), do: nil

  defp comparison_section(summary, comparison) when is_map(comparison) do
    """
    ## StandardAgent vs RLM
    - StandardAgent objective: #{inspect(objective_status(summary))}
    - RLM objective: #{inspect(objective_status(comparison))}
    - StandardAgent independent success: #{inspect(independent_success?(summary))}
    - RLM independent success: #{inspect(independent_success?(comparison))}
    """
    |> String.trim()
  end

  defp evidence_table([]), do: nil

  defp evidence_table(verifications) do
    verifications
    |> Enum.map(fn verification ->
      tool = field(verification, :tool) || "verification"
      status = field(verification, :status) || "unknown"
      command = field(verification, :argv) || field(verification, :command)
      cwd = field(verification, :cwd)

      "- `#{tool}` #{status} #{format_command(command)}#{format_cwd(cwd)}"
    end)
    |> Enum.join("\n")
  end

  defp scorecard_failures(nil), do: nil

  defp scorecard_failures(scorecard) do
    failures =
      scorecard
      |> field(:blocking_acceptance)
      |> List.wrap()
      |> Enum.map(fn result ->
        id = field(result, :id) || field(result, :type) || "acceptance"
        message = field(result, :message) || "blocking"
        "- `#{id}`: #{message}"
      end)

    if failures == [], do: nil, else: Enum.join(failures, "\n")
  end

  defp verified_complete?(summary) do
    objective_status(summary) in [:objective_satisfied, "objective_satisfied"] and
      independent_success?(summary) != false
  end

  defp objective_status(summary) do
    agent_summary = agent_summary(summary)

    field(summary, :objective_status) ||
      field(agent_summary, :objective_status) ||
      field(field(agent_summary, :objective_scorecard) || %{}, :objective_status)
  end

  defp independent_success?(summary) do
    cond do
      not is_nil(field(summary, :independent_success?)) ->
        field(summary, :independent_success?)

      checks = field(summary, :independent_checks) ->
        Enum.all?(checks, fn {_name, value} -> check_passed?(value) end)

      true ->
        nil
    end
  end

  defp check_passed?(value) when is_boolean(value), do: value
  defp check_passed?(value) when is_map(value), do: field(value, :status) in [:pass, "pass", true]
  defp check_passed?(_value), do: false

  defp check_status(value) when is_boolean(value), do: inspect(value)
  defp check_status(value) when is_map(value), do: inspect(field(value, :status) || value)
  defp check_status(value), do: inspect(value)

  defp reply(summary) do
    agent_summary = agent_summary(summary)

    field(agent_summary, :reply) ||
      field(summary, :reply) ||
      field(summary, :output) ||
      ""
  end

  defp completion_claim?(text) when is_binary(text) do
    text = String.downcase(text)

    Enum.any?(["complete", "completed", "done", "success", "satisfied"], fn marker ->
      String.contains?(text, marker)
    end)
  end

  defp completion_claim?(_text), do: false

  defp agent_summary(summary), do: field(summary, :agent_summary) || summary

  defp inspect_field(summary, key), do: inspect(field(summary, key))

  defp inline_list([]), do: "none"
  defp inline_list(values), do: values |> Enum.map(&"`#{&1}`") |> Enum.join(", ")

  defp trace_count(trace) when is_list(trace), do: length(trace)
  defp trace_count(%{events: events}) when is_list(events), do: length(events)
  defp trace_count(%{"events" => events}) when is_list(events), do: length(events)
  defp trace_count(_trace), do: 0

  defp maybe_bullet(_label, nil), do: nil
  defp maybe_bullet(_label, ""), do: nil
  defp maybe_bullet(label, value), do: "- #{label}: #{value}"

  defp risk_lines([]), do: "- No residual risks reported."
  defp risk_lines(risks), do: risks |> Enum.map(&"- #{&1}") |> Enum.join("\n")

  defp format_command(nil), do: ""
  defp format_command(command) when is_list(command), do: " `#{Enum.join(command, " ")}`"
  defp format_command(command), do: " `#{command}`"

  defp format_cwd(nil), do: ""
  defp format_cwd(cwd), do: " from `#{cwd}`"

  defp truncate(nil, _limit), do: nil
  defp truncate(text, limit) when is_binary(text) and byte_size(text) <= limit, do: text
  defp truncate(text, limit) when is_binary(text), do: binary_part(text, 0, limit) <> "..."
  defp truncate(other, limit), do: other |> inspect() |> truncate(limit)

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp field(_map, _key), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
