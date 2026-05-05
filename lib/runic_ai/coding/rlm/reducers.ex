defmodule RunicAI.Coding.RLM.Reducers do
  @moduledoc """
  Deterministic reducers for coding RLM artifacts.
  """

  alias RunicAI.Coding.RLM.Artifact
  alias RunicAI.Coding.RLM.ContractFact
  alias RunicAI.Coding.RLM.Finding
  alias RunicAI.Coding.RLM.PatchPlan
  alias RunicAI.Coding.RLM.RepairNeed
  alias RunicAI.Coding.RLM.Risk
  alias RunicAI.Coding.RLM.VerificationObservation

  @max_report_entries 50
  @max_file_content_chars 4_000
  @max_command_output_chars 6_000

  @spec reduce_findings([term()]) :: [Finding.t()]
  def reduce_findings(values) when is_list(values) do
    values
    |> Enum.flat_map(&extract_findings/1)
    |> Enum.uniq_by(&String.downcase(&1.summary))
    |> Enum.sort_by(&finding_rank/1, :desc)
  end

  @spec reduce_contracts([term()]) :: [ContractFact.t()]
  def reduce_contracts(values) when is_list(values) do
    values
    |> Enum.flat_map(&extract_contracts/1)
    |> Enum.uniq_by(&{String.downcase(&1.subject), String.downcase(&1.fact)})
    |> Enum.sort_by(& &1.subject)
  end

  @spec reduce_risks([term()]) :: [Risk.t()]
  def reduce_risks(values) when is_list(values) do
    values
    |> Enum.flat_map(&extract_risks/1)
    |> Enum.uniq_by(&String.downcase(&1.summary))
    |> Enum.sort_by(&risk_rank/1, :desc)
  end

  @spec reduce_patch_plan([term()], keyword()) :: PatchPlan.t()
  def reduce_patch_plan(values, opts \\ []) when is_list(values) and is_list(opts) do
    findings = reduce_findings(values)
    contracts = reduce_contracts(values)
    risks = reduce_risks(values)

    steps =
      findings
      |> Enum.map(fn finding ->
        %{action: :inspect_or_edit, summary: finding.summary, evidence: finding.evidence}
      end)

    verification =
      values
      |> Enum.flat_map(&extract_verifications/1)
      |> case do
        [] -> [%{tool: :run_tests, scope: :targeted_first}]
        observations -> Enum.map(observations, &%{status: &1.status, command: &1.command})
      end

    PatchPlan.new!(
      steps,
      verification: verification,
      write_scope: Keyword.get(opts, :write_scope, []),
      metadata: %{
        finding_count: length(findings),
        contract_count: length(contracts),
        risk_count: length(risks)
      }
    )
  end

  @spec reduce_verification([term()]) :: [VerificationObservation.t()]
  def reduce_verification(values) when is_list(values) do
    values
    |> Enum.flat_map(&extract_verifications/1)
    |> Enum.uniq_by(&{&1.command, &1.status, &1.output_preview})
  end

  @spec repair_needs([VerificationObservation.t()]) :: [RepairNeed.t()]
  def repair_needs(observations) when is_list(observations) do
    observations
    |> Enum.reject(&(&1.status in [:pass, :skipped]))
    |> Enum.map(fn observation ->
      RepairNeed.new!(
        "verification #{observation.status}: #{format_command(observation.command)}",
        target: observation.command,
        evidence: [observation],
        metadata: %{status: observation.status}
      )
    end)
  end

  @spec reduce(atom() | String.t(), [term()], keyword()) :: term()
  def reduce(kind, values, opts \\ [])

  def reduce(:findings, values, _opts), do: reduce_findings(values)
  def reduce("findings", values, opts), do: reduce(:findings, values, opts)
  def reduce(:contracts, values, _opts), do: reduce_contracts(values)
  def reduce("contracts", values, opts), do: reduce(:contracts, values, opts)
  def reduce(:risks, values, _opts), do: reduce_risks(values)
  def reduce("risks", values, opts), do: reduce(:risks, values, opts)
  def reduce(:patch_plan, values, opts), do: reduce_patch_plan(values, opts)
  def reduce("patch_plan", values, opts), do: reduce(:patch_plan, values, opts)
  def reduce(:verification, values, _opts), do: reduce_verification(values)
  def reduce("verification", values, opts), do: reduce(:verification, values, opts)
  def reduce(:report, values, _opts), do: report(values)
  def reduce("report", values, opts), do: reduce(:report, values, opts)
  def reduce(_kind, values, _opts), do: report(values)

  defp extract_findings(%Finding{} = finding), do: [finding]
  defp extract_findings(%Artifact{kind: :finding, content: %Finding{} = finding}), do: [finding]

  defp extract_findings(%Artifact{kind: :finding, content: content}) when is_binary(content),
    do: [Finding.new!(content)]

  defp extract_findings(%{finding: finding}) when is_binary(finding), do: [Finding.new!(finding)]

  defp extract_findings(%{"finding" => finding}) when is_binary(finding),
    do: [Finding.new!(finding)]

  defp extract_findings(values) when is_list(values),
    do: Enum.flat_map(values, &extract_findings/1)

  defp extract_findings(_value), do: []

  defp extract_contracts(%ContractFact{} = contract), do: [contract]

  defp extract_contracts(%Artifact{kind: :contract_fact, content: %ContractFact{} = contract}),
    do: [contract]

  defp extract_contracts(%{subject: subject, fact: fact})
       when is_binary(subject) and is_binary(fact),
       do: [ContractFact.new!(subject, fact)]

  defp extract_contracts(values) when is_list(values),
    do: Enum.flat_map(values, &extract_contracts/1)

  defp extract_contracts(_value), do: []

  defp extract_risks(%Risk{} = risk), do: [risk]
  defp extract_risks(%Artifact{kind: :risk, content: %Risk{} = risk}), do: [risk]
  defp extract_risks(%{risk: risk}) when is_binary(risk), do: [Risk.new!(risk)]
  defp extract_risks(%{"risk" => risk}) when is_binary(risk), do: [Risk.new!(risk)]
  defp extract_risks(values) when is_list(values), do: Enum.flat_map(values, &extract_risks/1)
  defp extract_risks(_value), do: []

  defp extract_verifications(%VerificationObservation{} = observation), do: [observation]

  defp extract_verifications(%Artifact{
         kind: :verification_observation,
         content: %VerificationObservation{} = observation
       }),
       do: [observation]

  defp extract_verifications(%{status: status} = value) do
    [
      VerificationObservation.new!(status,
        command: Map.get(value, :command),
        output_preview: Map.get(value, :output_preview, "")
      )
    ]
  rescue
    ArgumentError -> []
  end

  defp extract_verifications(values) when is_list(values),
    do: Enum.flat_map(values, &extract_verifications/1)

  defp extract_verifications(_value), do: []

  defp finding_rank(%Finding{} = finding),
    do: severity_rank(finding.severity) + finding.confidence

  defp risk_rank(%Risk{} = risk), do: severity_rank(risk.level)

  defp severity_rank(:critical), do: 5
  defp severity_rank(:high), do: 4
  defp severity_rank(:medium), do: 3
  defp severity_rank(:low), do: 2
  defp severity_rank(:info), do: 1
  defp severity_rank(_severity), do: 0

  defp report(values) do
    values
    |> List.wrap()
    |> List.flatten()
    |> Enum.map(&format_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp format_value(%{output: output}), do: format_value(output)
  defp format_value(%Artifact{} = artifact), do: format_value(artifact.content)
  defp format_value(value) when is_binary(value), do: value

  defp format_value(value) when is_map(value) do
    cond do
      is_list(field(value, :files)) ->
        format_file_collection(value)

      is_list(field(value, :entries)) ->
        format_entry_collection(value)

      is_list(field(value, :matches)) ->
        format_match_collection(value)

      file_entry?(value) ->
        format_file_entry(value)

      command_result?(value) ->
        format_command_output(value)

      true ->
        fenced("elixir", inspect(value, pretty: true, limit: 50, printable_limit: 2_000))
    end
  end

  defp format_value(value), do: inspect(value)

  defp format_file_collection(value) do
    files = field(value, :files) || []
    count = field(value, :count) || length(files)

    header =
      "## File output\n\n" <>
        "#{length(files)} of #{count} files" <> truncated_suffix(value)

    body =
      files
      |> Enum.take(@max_report_entries)
      |> Enum.map(&format_file_collection_entry/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    [header, body, omitted_suffix(files)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp format_file_collection_entry(entry) do
    if file_entry_has_content?(entry) do
      format_file_entry(entry)
    else
      "- `#{field(entry, :path) || field(entry, :name) || inspect(entry)}`#{file_metadata(entry)}"
    end
  end

  defp format_entry_collection(value) do
    entries = field(value, :entries) || []
    count = field(value, :count) || length(entries)
    path = field(value, :path)

    header =
      ["## Directory listing", path && "`#{path}`", "#{length(entries)} of #{count} entries"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    body =
      entries
      |> Enum.take(@max_report_entries)
      |> Enum.map(fn entry ->
        name = field(entry, :path) || field(entry, :name) || inspect(entry)
        type = field(entry, :type)
        "- `#{name}`#{if type, do: " (#{type})", else: ""}#{file_metadata(entry)}"
      end)
      |> Enum.join("\n")

    [header, body, omitted_suffix(entries)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp format_match_collection(value) do
    matches = field(value, :matches) || []
    count = field(value, :count) || length(matches)

    header =
      "## Search results\n\n" <>
        "#{length(matches)} of #{count} matches" <> truncated_suffix(value)

    body =
      matches
      |> Enum.take(@max_report_entries)
      |> Enum.map(&format_match_entry/1)
      |> Enum.join("\n")

    [header, body, omitted_suffix(matches)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp format_match_entry(match) do
    path = field(match, :path) || "unknown"
    line = field(match, :line) || field(match, :line_number)
    text = field(match, :text) || field(match, :match) || field(match, :line_text)

    location =
      if line do
        "#{path}:#{line}"
      else
        path
      end

    "- `#{location}` #{String.trim(to_string(text || ""))}"
  end

  defp format_file_entry(entry) do
    path = field(entry, :path) || field(entry, :name) || "file"

    cond do
      field(entry, :failure) ->
        "### `#{path}`\n\nError: #{format_failure(field(entry, :failure))}"

      truthy?(field(entry, :binary?)) ->
        "### `#{path}`\n\nBinary file#{file_metadata(entry)}"

      true ->
        content = field(entry, :content) || field(entry, :text) || field(entry, :preview) || ""
        language = fence_language(path)

        "### `#{path}`#{file_metadata(entry)}\n\n" <>
          fenced(language, truncate_content(content, @max_file_content_chars))
    end
  end

  defp format_command_output(value) do
    status = field(value, :status) || field(value, :exit_status)
    command = field(value, :command) || field(value, :argv)
    stdout = field(value, :stdout) || field(value, :output) || ""
    stderr = field(value, :stderr) || ""

    [
      "## Command output",
      command && "`#{format_command(command)}`",
      status && "status: #{status}",
      stdout != "" &&
        "### stdout\n\n" <> fenced("", truncate_content(stdout, @max_command_output_chars)),
      stderr != "" &&
        "### stderr\n\n" <> fenced("", truncate_content(stderr, @max_command_output_chars))
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n\n")
  end

  defp file_entry?(value) do
    not is_nil(field(value, :path)) and
      Enum.any?([:content, :preview, :text, :binary?, :failure], &(not is_nil(field(value, &1))))
  end

  defp file_entry_has_content?(value) do
    Enum.any?([:content, :preview, :text, :binary?, :failure], &(not is_nil(field(value, &1))))
  end

  defp command_result?(value) do
    Enum.any?([:stdout, :stderr, :exit_status, :command, :argv], &(not is_nil(field(value, &1))))
  end

  defp file_metadata(value) do
    parts =
      [
        byte_size_label(field(value, :byte_size) || field(value, :bytes)),
        truthy?(field(value, :truncated?)) && "truncated"
      ]
      |> Enum.reject(&(&1 in [nil, false, ""]))

    if parts == [] do
      ""
    else
      " (#{Enum.join(parts, ", ")})"
    end
  end

  defp byte_size_label(nil), do: nil
  defp byte_size_label(bytes) when is_integer(bytes), do: "#{bytes} bytes"
  defp byte_size_label(bytes), do: "#{bytes} bytes"

  defp truncated_suffix(value) do
    if truthy?(field(value, :truncated?)), do: " (truncated)", else: ""
  end

  defp omitted_suffix(values) when length(values) > @max_report_entries do
    "_#{length(values) - @max_report_entries} more omitted from terminal report._"
  end

  defp omitted_suffix(_values), do: nil

  defp format_failure(failure) when is_map(failure) do
    field(failure, :error) || inspect(failure, pretty: true, limit: 20)
  end

  defp format_failure(failure), do: to_string(failure)

  defp truncate_content(content, max_chars) when is_binary(content) do
    if String.length(content) > max_chars do
      String.slice(content, 0, max_chars) <> "\n\n[truncated for terminal report]"
    else
      content
    end
  end

  defp truncate_content(content, _max_chars), do: inspect(content)

  defp fenced(language, content) do
    fence = if String.contains?(content, "```"), do: "````", else: "```"
    language = language || ""
    "#{fence}#{language}\n#{content}\n#{fence}"
  end

  defp fence_language(path) when is_binary(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".heex" -> "heex"
      ".livemd" -> "markdown"
      ".md" -> "markdown"
      ".markdown" -> "markdown"
      ".json" -> "json"
      ".js" -> "javascript"
      ".jsx" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "typescript"
      ".py" -> "python"
      ".sh" -> "sh"
      ".bash" -> "sh"
      ".zsh" -> "sh"
      ".sql" -> "sql"
      ".diff" -> "diff"
      ".patch" -> "diff"
      _other -> ""
    end
  end

  defp fence_language(_path), do: ""

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  defp truthy?(value), do: value in [true, "true", 1]

  defp format_command(command) when is_list(command), do: Enum.join(command, " ")
  defp format_command(command) when is_binary(command), do: command
  defp format_command(nil), do: "unknown command"
  defp format_command(command), do: inspect(command)
end
