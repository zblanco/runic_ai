defmodule RunicAI.Persistence.Queries do
  @moduledoc """
  Composable Ecto queries for RunicAI durability, tracing, and eval inspection.
  """

  import Ecto.Query

  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.ManagedWorkflow
  alias RunicAI.Persistence.Schemas.RepairAttempt
  alias RunicAI.Persistence.Schemas.ReviewRequest
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.RunnableEvent
  alias RunicAI.Persistence.Schemas.Scorecard
  alias RunicAI.Persistence.Schemas.TerminalEvent
  alias RunicAI.Persistence.Schemas.ToolCall
  alias RunicAI.Persistence.Schemas.WorkflowEvent
  alias RunicAI.Persistence.Schemas.WorkflowFact
  alias RunicAI.Persistence.Schemas.WorkflowRun

  @spec recent_runs_query(keyword()) :: Ecto.Query.t()
  def recent_runs_query(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(run in WorkflowRun,
      order_by: [desc: run.started_at, desc: run.inserted_at],
      limit: ^limit
    )
  end

  @spec recent_runs(Store.t(), keyword()) :: [WorkflowRun.t()]
  def recent_runs(%Store{} = store, opts \\ []) do
    SQLite.with_repo(store, fn -> store.repo.all(recent_runs_query(opts)) end)
  end

  @spec latest_run_for_workflow_query(String.t()) :: Ecto.Query.t()
  def latest_run_for_workflow_query(workflow_key) when is_binary(workflow_key) do
    from(run in WorkflowRun,
      where: run.workflow_key == ^workflow_key,
      order_by: [desc: run.started_at, desc: run.inserted_at],
      limit: 1
    )
  end

  @spec latest_run_for_workflow(Store.t(), String.t()) :: WorkflowRun.t() | nil
  def latest_run_for_workflow(%Store{} = store, workflow_key) do
    SQLite.with_repo(store, fn -> store.repo.one(latest_run_for_workflow_query(workflow_key)) end)
  end

  @spec run_timeline_query(String.t()) :: Ecto.Query.t()
  def run_timeline_query(run_id) when is_binary(run_id) do
    from(event in TerminalEvent,
      where: event.run_id == ^run_id,
      order_by: [asc: event.sequence, asc: event.at]
    )
  end

  @spec run_timeline(Store.t(), String.t()) :: [TerminalEvent.t()]
  def run_timeline(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.all(run_timeline_query(run_id)) end)
  end

  @spec workflow_events_query(String.t()) :: Ecto.Query.t()
  def workflow_events_query(run_id) when is_binary(run_id) do
    from(event in WorkflowEvent,
      where: event.run_id == ^run_id,
      order_by: [asc: event.sequence]
    )
  end

  @spec workflow_events(Store.t(), String.t()) :: [WorkflowEvent.t()]
  def workflow_events(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.all(workflow_events_query(run_id)) end)
  end

  @spec failed_runnables_query(String.t()) :: Ecto.Query.t()
  def failed_runnables_query(run_id) when is_binary(run_id) do
    from(event in RunnableEvent,
      where: event.run_id == ^run_id and event.status in ["error", "failed"],
      order_by: [asc: event.sequence]
    )
  end

  @spec failed_runnables(Store.t(), String.t()) :: [RunnableEvent.t()]
  def failed_runnables(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.all(failed_runnables_query(run_id)) end)
  end

  @spec runnable_events_query(String.t()) :: Ecto.Query.t()
  def runnable_events_query(run_id) when is_binary(run_id) do
    from(event in RunnableEvent,
      where: event.run_id == ^run_id,
      order_by: [asc: event.sequence]
    )
  end

  @spec runnable_events(Store.t(), String.t()) :: [RunnableEvent.t()]
  def runnable_events(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.all(runnable_events_query(run_id)) end)
  end

  @spec tool_calls_query(String.t()) :: Ecto.Query.t()
  def tool_calls_query(run_id) when is_binary(run_id) do
    from(call in ToolCall,
      where: call.workflow_run_id == ^run_id,
      order_by: [asc: call.requested_at, asc: call.started_at]
    )
  end

  @spec tool_calls(Store.t(), String.t()) :: [ToolCall.t()]
  def tool_calls(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.all(tool_calls_query(run_id)) end)
  end

  @spec conversation_messages_query(String.t()) :: Ecto.Query.t()
  def conversation_messages_query(conversation_id) when is_binary(conversation_id) do
    from(message in AgentMessage,
      where: message.conversation_id == ^conversation_id,
      order_by: [asc: message.created_at]
    )
  end

  @spec conversation_messages(Store.t(), String.t()) :: [AgentMessage.t()]
  def conversation_messages(%Store{} = store, conversation_id) do
    SQLite.with_repo(store, fn ->
      store.repo.all(conversation_messages_query(conversation_id))
    end)
  end

  @spec artifacts_for_run_query(String.t()) :: Ecto.Query.t()
  def artifacts_for_run_query(run_id) when is_binary(run_id) do
    from(artifact in RunArtifact,
      where: artifact.run_id == ^run_id,
      order_by: [asc: artifact.inserted_at]
    )
  end

  @spec artifacts_for_run(Store.t(), String.t()) :: [RunArtifact.t()]
  def artifacts_for_run(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.all(artifacts_for_run_query(run_id)) end)
  end

  @spec scorecards_for_run_query(String.t()) :: Ecto.Query.t()
  def scorecards_for_run_query(run_id) when is_binary(run_id) do
    from(scorecard in Scorecard,
      where: scorecard.run_id == ^run_id,
      order_by: [asc: scorecard.created_at]
    )
  end

  @spec scorecards_for_run(Store.t(), String.t()) :: [Scorecard.t()]
  def scorecards_for_run(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.all(scorecards_for_run_query(run_id)) end)
  end

  @spec scorecards_for_status_query(String.t()) :: Ecto.Query.t()
  def scorecards_for_status_query(objective_status) when is_binary(objective_status) do
    from(scorecard in Scorecard,
      where: scorecard.objective_status == ^objective_status,
      order_by: [desc: scorecard.created_at]
    )
  end

  @spec scorecards_for_status(Store.t(), String.t()) :: [Scorecard.t()]
  def scorecards_for_status(%Store{} = store, objective_status) do
    SQLite.with_repo(store, fn ->
      store.repo.all(scorecards_for_status_query(objective_status))
    end)
  end

  @spec repair_attempts_query(String.t()) :: Ecto.Query.t()
  def repair_attempts_query(run_id) when is_binary(run_id) do
    from(repair in RepairAttempt,
      where: repair.run_id == ^run_id,
      order_by: [asc: repair.sequence]
    )
  end

  @spec repair_attempts(Store.t(), String.t()) :: [RepairAttempt.t()]
  def repair_attempts(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.all(repair_attempts_query(run_id)) end)
  end

  @spec review_requests_query(String.t()) :: Ecto.Query.t()
  def review_requests_query(run_id) when is_binary(run_id) do
    from(request in ReviewRequest,
      where: request.workflow_run_id == ^run_id,
      order_by: [asc: request.inserted_at]
    )
  end

  @spec review_requests(Store.t(), String.t()) :: [ReviewRequest.t()]
  def review_requests(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.all(review_requests_query(run_id)) end)
  end

  @spec facts_for_node_query(String.t(), String.t()) :: Ecto.Query.t()
  def facts_for_node_query(run_id, node_name) when is_binary(run_id) and is_binary(node_name) do
    from(fact in WorkflowFact,
      where: fact.run_id == ^run_id and fact.producer_node == ^node_name,
      order_by: [asc: fact.inserted_at]
    )
  end

  @spec facts_for_node(Store.t(), String.t(), String.t()) :: [WorkflowFact.t()]
  def facts_for_node(%Store{} = store, run_id, node_name) do
    SQLite.with_repo(store, fn -> store.repo.all(facts_for_node_query(run_id, node_name)) end)
  end

  @spec search_events_query(String.t()) :: Ecto.Query.t()
  def search_events_query(term) when is_binary(term) do
    term = fts_term(term)

    from(event in TerminalEvent,
      where:
        fragment(
          """
          ? IN (
            SELECT terminal_events.id
            FROM terminal_events
            JOIN terminal_events_fts ON terminal_events.rowid = terminal_events_fts.rowid
            WHERE terminal_events_fts MATCH ?
          )
          """,
          event.id,
          ^term
        ),
      order_by: [asc: event.at]
    )
  end

  @spec search_events(Store.t(), String.t()) :: [TerminalEvent.t()]
  def search_events(%Store{} = store, term) do
    SQLite.with_repo(store, fn -> store.repo.all(search_events_query(term)) end)
  end

  defp fts_term(term) do
    if String.match?(term, ~r/^[[:alnum:]_]+$/) do
      term
    else
      ~s("#{String.replace(term, ~s("), ~s(""))}")
    end
  end

  @spec managed_workflows_query(keyword()) :: Ecto.Query.t()
  def managed_workflows_query(opts \\ []) do
    statuses =
      opts
      |> Keyword.get(:status)
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    query =
      from(workflow in ManagedWorkflow,
        order_by: [asc: workflow.workflow_key]
      )

    if statuses == [] do
      query
    else
      from(workflow in query, where: workflow.status in ^statuses)
    end
  end

  @spec managed_workflows(Store.t(), keyword()) :: [ManagedWorkflow.t()]
  def managed_workflows(%Store{} = store, opts \\ []) do
    SQLite.with_repo(store, fn -> store.repo.all(managed_workflows_query(opts)) end)
  end

  @spec pending_managed_workflows(Store.t()) :: [ManagedWorkflow.t()]
  def pending_managed_workflows(%Store{} = store), do: managed_workflows(store, status: :pending)

  @spec active_managed_workflows(Store.t()) :: [ManagedWorkflow.t()]
  def active_managed_workflows(%Store{} = store), do: managed_workflows(store, status: :active)

  @spec failed_managed_workflows(Store.t()) :: [ManagedWorkflow.t()]
  def failed_managed_workflows(%Store{} = store), do: managed_workflows(store, status: :failed)

  @spec paused_managed_workflows(Store.t()) :: [ManagedWorkflow.t()]
  def paused_managed_workflows(%Store{} = store), do: managed_workflows(store, status: :paused)

  @spec scheduled_managed_workflows(Store.t()) :: [ManagedWorkflow.t()]
  def scheduled_managed_workflows(%Store{} = store),
    do: managed_workflows(store, status: :scheduled)
end
