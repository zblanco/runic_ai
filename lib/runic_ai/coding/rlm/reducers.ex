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
  defp format_value(value), do: inspect(value)

  defp format_command(command) when is_list(command), do: Enum.join(command, " ")
  defp format_command(command) when is_binary(command), do: command
  defp format_command(nil), do: "unknown command"
  defp format_command(command), do: inspect(command)
end
