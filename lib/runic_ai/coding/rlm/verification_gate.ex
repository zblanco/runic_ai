defmodule RunicAI.Coding.RLM.VerificationGate do
  @moduledoc """
  Deterministic verification gate for RLM coding workflows.

  A gate evaluates an acceptance contract against current workspace state and
  observed command/child artifacts, then emits a scorecard and repair needs.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.AcceptanceContract
  alias RunicAI.Coding.RLM.ExecutionEvidence
  alias RunicAI.Coding.RLM.RepairController
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.Workspace

  @spec run(Workspace.t(), AcceptanceContract.t() | map(), map(), keyword()) ::
          {:ok, map()} | {:error, RunicAI.Error.t()}
  def run(%Workspace{} = workspace, contract_input, context \\ %{}, opts \\ [])
      when is_map(context) and is_list(opts) do
    with {:ok, contract} <- AcceptanceContract.from_input(contract_input),
         {:ok, evaluation} <- AcceptanceContract.evaluate(contract, workspace, context) do
      child_results = List.wrap(Map.get(context, :child_results, []))
      command_statuses = command_statuses(context)
      changed_files = changed_files(context, child_results)

      acceptance_results =
        maybe_require_execution_evidence(evaluation.results, contract, context, opts)

      scorecard =
        WorkflowScorecard.new!(
          acceptance_results: acceptance_results,
          child_results: child_results,
          command_statuses: command_statuses,
          changed_files: changed_files,
          repair_count: Keyword.get(opts, :repair_count, 0),
          residual_risks: residual_risks(context, child_results, evaluation.results),
          metadata: %{contract_id: contract.id, objective: contract.objective}
        )

      repair_needs = RepairController.from_scorecard(scorecard, acceptance_results)

      {:ok,
       %{
         status: scorecard.objective_status,
         contract: contract,
         evaluation: evaluation,
         scorecard: scorecard,
         repair_needs: repair_needs
       }}
    end
  end

  defp maybe_require_execution_evidence(results, contract, context, opts) do
    if execution_evidence_required?(contract, opts) do
      results ++ [ExecutionEvidence.result(context)]
    else
      results
    end
  end

  defp execution_evidence_required?(%AcceptanceContract{} = contract, opts) do
    Keyword.get(opts, :require_execution_evidence?, mutation_required?(contract.metadata))
  end

  defp mutation_required?(metadata) when is_map(metadata) do
    field(metadata, :mutation_required?) in [true, "true"]
  end

  defp mutation_required?(_metadata), do: false

  defp command_statuses(context) do
    []
    |> Kernel.++(List.wrap(Map.get(context, :command_results, [])))
    |> Kernel.++(List.wrap(Map.get(context, :verification_observations, [])))
    |> Kernel.++(List.wrap(Map.get(context, :verifications, [])))
  end

  defp changed_files(context, child_results) do
    context_files = List.wrap(Map.get(context, :changed_files, []))

    child_files =
      Enum.flat_map(child_results, fn child ->
        List.wrap(field(child, :changed_files))
      end)

    Enum.uniq(context_files ++ child_files)
  end

  defp residual_risks(context, child_results, acceptance_results) do
    context_risks = List.wrap(Map.get(context, :risks, []))

    child_risks =
      Enum.flat_map(child_results, fn child ->
        List.wrap(field(child, :unresolved_risks) || field(child, :risks))
      end)

    risks = Enum.uniq(context_risks ++ child_risks)

    if Enum.any?(acceptance_results, &AcceptanceCheck.blocking_failure?/1) do
      risks
    else
      Enum.reject(risks, &superseded_execution_risk?/1)
    end
  end

  defp superseded_execution_risk?(risk) when is_binary(risk) do
    String.starts_with?(risk, ["verification was not run", "turn ended with error: provider:"])
  end

  defp superseded_execution_risk?(_risk), do: false

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_value, _key), do: nil
end
