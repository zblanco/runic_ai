defmodule RunicAI.Persistence.Evals do
  @moduledoc """
  Helpers for pulling durable run cohorts into eval and prompt-tuning workflows.
  """

  import Ecto.Query

  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.RepairAttempt
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.Scorecard
  alias RunicAI.Persistence.Schemas.ToolCall
  alias RunicAI.Persistence.Schemas.WorkflowRun

  @spec cohort(Store.t(), keyword()) :: [map()]
  def cohort(%Store{} = store, opts \\ []) do
    run_ids = Keyword.get(opts, :run_ids) || run_ids_for_cohort(store, opts)
    Enum.map(run_ids, &run_record(store, &1))
  end

  @spec run_record(Store.t(), String.t()) :: map()
  def run_record(%Store{} = store, run_id) do
    %{
      run: get_run(store, run_id),
      scorecards: Queries.scorecards_for_run(store, run_id),
      messages: messages_for_run(store, run_id),
      tool_calls: Queries.tool_calls(store, run_id),
      repairs: Queries.repair_attempts(store, run_id),
      artifacts: Queries.artifacts_for_run(store, run_id),
      metrics: derived_metrics(store, run_id)
    }
  end

  @spec compare_by_objective_status(Store.t(), keyword()) :: map()
  def compare_by_objective_status(%Store{} = store, opts \\ []) do
    store
    |> cohort(opts)
    |> Enum.group_by(fn record ->
      record.scorecards
      |> List.last()
      |> case do
        nil -> "unknown"
        scorecard -> scorecard.objective_status
      end
    end)
    |> Map.new(fn {status, records} -> {status, length(records)} end)
  end

  defp run_ids_for_cohort(%Store{} = store, opts) do
    limit = Keyword.get(opts, :limit, 20)
    objective_status = Keyword.get(opts, :objective_status)

    SQLite.with_repo(store, fn ->
      query =
        from(run in WorkflowRun,
          order_by: [desc: run.started_at, desc: run.inserted_at],
          limit: ^limit,
          select: run.id
        )

      query =
        if objective_status do
          objective_status = to_string(objective_status)

          from(run in query,
            join: scorecard in Scorecard,
            on: scorecard.run_id == run.id,
            where: scorecard.objective_status == ^objective_status
          )
        else
          query
        end

      store.repo.all(query)
    end)
  end

  defp get_run(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.get(WorkflowRun, run_id) end)
  end

  defp messages_for_run(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn ->
      store.repo.all(
        from(message in AgentMessage,
          where: message.presentation_group_id == ^run_id or message.session_id == ^run_id,
          order_by: [asc: message.created_at]
        )
      )
    end)
  end

  defp derived_metrics(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn ->
      %{
        scorecard_count:
          store.repo.one(
            from(scorecard in Scorecard, where: scorecard.run_id == ^run_id, select: count())
          ),
        message_count:
          store.repo.one(
            from(message in AgentMessage,
              where: message.presentation_group_id == ^run_id or message.session_id == ^run_id,
              select: count()
            )
          ),
        tool_call_count:
          store.repo.one(
            from(call in ToolCall, where: call.workflow_run_id == ^run_id, select: count())
          ),
        artifact_count:
          store.repo.one(
            from(artifact in RunArtifact, where: artifact.run_id == ^run_id, select: count())
          ),
        repair_count:
          store.repo.one(
            from(repair in RepairAttempt, where: repair.run_id == ^run_id, select: count())
          )
      }
    end)
  end
end
