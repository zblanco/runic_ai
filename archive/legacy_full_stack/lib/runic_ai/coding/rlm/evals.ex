defmodule RunicAI.Coding.RLM.Evals do
  @moduledoc """
  Deterministic evaluation fixtures for the RLM coding agent.
  """

  alias RunicAI.Coding.RLM.Agent
  alias RunicAI.Coding.RLM.RecipeLibrary

  @spec cases(keyword()) :: [map()]
  def cases(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    [
      %{
        id: "rlm_coding:repo_qa",
        objective: "Find where the coding agent default model is configured.",
        workspace: workspace,
        command: :repo_qa,
        expected: [:proposal_accepted]
      },
      %{
        id: "rlm_coding:bug_investigation",
        objective: "Investigate a failing test log and rank likely causes.",
        workspace: workspace,
        command: :bug_investigation,
        expected: [:proposal_accepted]
      },
      %{
        id: "rlm_coding:patch_planning",
        objective: "Plan a narrow patch and verification strategy.",
        workspace: workspace,
        command: :patch_planning,
        expected: [:proposal_accepted]
      }
    ]
  end

  @spec run([map()], keyword()) :: map()
  def run(cases, opts \\ []) when is_list(cases) and is_list(opts) do
    results =
      Enum.map(cases, fn evaluation_case ->
        run_case(evaluation_case, opts)
      end)

    %{
      results: results,
      aggregate: %{
        cases: length(results),
        passed: Enum.count(results, &(&1.status == :passed)),
        failed: Enum.count(results, &(&1.status == :failed))
      }
    }
  end

  defp run_case(evaluation_case, opts) do
    proposal =
      RecipeLibrary.proposal(evaluation_case.command, evaluation_case.objective)

    run_opts =
      opts
      |> Keyword.put(:proposal, proposal)
      |> Keyword.put(:command, evaluation_case.command)

    case Agent.run(evaluation_case.workspace, evaluation_case.objective, run_opts) do
      {:ok, result} ->
        %{
          id: evaluation_case.id,
          status: if(result.validation_report.status == :accepted, do: :passed, else: :failed),
          proposal: result.proposal,
          accepted_graph: result.validation_report.accepted_nodes,
          output: result.output,
          source_refs:
            result.codebase_environment
            |> RunicAI.Coding.RLM.CodebaseEnvironment.source_summaries(20)
        }

      {:error, error} ->
        %{id: evaluation_case.id, status: :failed, error: error}
    end
  end
end
