defmodule RunicAI.Persistence.Inspection do
  @moduledoc """
  Read-side helpers for debugging durable agent and workflow runs.
  """

  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.Replay
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Schemas.WorkflowRun

  @spec run_timeline(Store.t(), String.t()) :: [map()]
  def run_timeline(%Store{} = store, run_id), do: Replay.compact_terminal_timeline(store, run_id)

  @spec graph_summary(Store.t(), String.t()) :: map() | nil
  def graph_summary(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn ->
      case store.repo.get(WorkflowRun, run_id) do
        %WorkflowRun{metadata_json: %{"graph_summary" => summary}} -> summary
        %WorkflowRun{metadata_json: %{graph_summary: summary}} -> summary
        _other -> graph_summary_from_artifacts(store, run_id)
      end
    end)
  end

  @spec failed_runnable(Store.t(), String.t()) :: map() | nil
  def failed_runnable(%Store{} = store, run_id) do
    store
    |> Queries.failed_runnables(run_id)
    |> List.first()
    |> case do
      nil ->
        nil

      event ->
        %{
          sequence: event.sequence,
          runnable_id: event.runnable_id,
          node_name: event.node_name,
          node_hash: event.node_hash,
          component_id: event.component_id,
          component_type: event.component_type,
          status: event.status,
          error: event.error_json,
          policy: event.policy_json
        }
    end
  end

  @spec artifact_trail(Store.t(), String.t()) :: [map()]
  def artifact_trail(%Store{} = store, run_id) do
    store
    |> Queries.artifacts_for_run(run_id)
    |> Enum.map(fn artifact ->
      %{
        id: artifact.id,
        path: artifact.path,
        kind: artifact.artifact_kind,
        action: artifact.action,
        sha256: artifact.sha256,
        byte_size: artifact.byte_size,
        metadata: artifact.metadata_json
      }
    end)
  end

  @spec scorecard_status(Store.t(), String.t()) :: map() | nil
  def scorecard_status(%Store{} = store, run_id) do
    store
    |> Queries.scorecards_for_run(run_id)
    |> List.last()
    |> case do
      nil ->
        nil

      scorecard ->
        %{
          objective_status: scorecard.objective_status,
          component_id: scorecard.component_id,
          scorecard: scorecard.scorecard_json,
          created_at: scorecard.created_at
        }
    end
  end

  @spec prompt_source_cue_search(Store.t(), String.t()) :: [map()]
  def prompt_source_cue_search(%Store{} = store, term) do
    store
    |> Queries.search_events(term)
    |> Enum.map(fn event ->
      %{
        run_id: event.run_id,
        sequence: event.sequence,
        kind: event.kind,
        phase: event.phase,
        status: event.status,
        title: event.title,
        detail: event.detail,
        data: event.data_json
      }
    end)
  end

  @spec repair_diagnostics(Store.t(), String.t()) :: [map()]
  def repair_diagnostics(%Store{} = store, run_id) do
    store
    |> Queries.repair_attempts(run_id)
    |> Enum.map(fn repair ->
      %{
        sequence: repair.sequence,
        strategy: repair.strategy,
        status: repair.status,
        reason: repair.reason_json,
        diagnostics: repair.diagnostics_json,
        proposal_before: repair.proposal_before_json,
        proposal_after: repair.proposal_after_json
      }
    end)
  end

  @spec repair_prompt(Store.t(), String.t()) :: String.t()
  def repair_prompt(%Store{} = store, run_id) do
    failure = failed_runnable(store, run_id)
    diagnostics = repair_diagnostics(store, run_id)
    scorecard = scorecard_status(store, run_id)

    """
    Repair durable RunicAI run #{run_id}.

    Failed runnable:
    #{inspect(failure, pretty: true, limit: 20)}

    Scorecard:
    #{inspect(scorecard, pretty: true, limit: 20)}

    Prior repair diagnostics:
    #{inspect(diagnostics, pretty: true, limit: 20)}
    """
    |> String.trim()
  end

  defp graph_summary_from_artifacts(store, run_id) do
    store
    |> Queries.artifacts_for_run(run_id)
    |> Enum.find(&(&1.artifact_kind == "workflow_graph"))
    |> case do
      nil -> nil
      artifact -> artifact.metadata_json
    end
  end
end
