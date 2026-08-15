defmodule RunicAI.Persistence.Queries do
  @moduledoc """
  Composable Ecto queries for RunicAI durability, tracing, and eval inspection.
  """

  import Ecto.Query

  alias RunicAI.Coding.RLM.ObjectiveSession
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.AgentSession
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

  @spec recent_sessions_query(keyword()) :: Ecto.Query.t()
  def recent_sessions_query(opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)

    from(session in AgentSession,
      order_by: [
        asc:
          fragment(
            "CASE ? WHEN 'running' THEN 0 WHEN 'review' THEN 1 WHEN 'waiting' THEN 2 WHEN 'failed' THEN 3 ELSE 4 END",
            session.status
          ),
        desc: session.started_at,
        desc: session.inserted_at
      ],
      limit: ^limit
    )
  end

  @spec recent_sessions(Store.t(), keyword()) :: [AgentSession.t()]
  def recent_sessions(%Store{} = store, opts \\ []) do
    SQLite.with_repo(store, fn -> store.repo.all(recent_sessions_query(opts)) end)
  end

  @spec get_session(Store.t(), String.t()) :: AgentSession.t() | nil
  def get_session(%Store{} = store, session_id) when is_binary(session_id) do
    SQLite.with_repo(store, fn -> store.repo.get(AgentSession, session_id) end)
  end

  @spec messages_for_session_query(String.t()) :: Ecto.Query.t()
  def messages_for_session_query(session_id) when is_binary(session_id) do
    from(message in AgentMessage,
      where: message.session_id == ^session_id,
      order_by: [asc: message.created_at]
    )
  end

  @spec messages_for_session(Store.t(), String.t()) :: [AgentMessage.t()]
  def messages_for_session(%Store{} = store, session_id) do
    SQLite.with_repo(store, fn -> store.repo.all(messages_for_session_query(session_id)) end)
  end

  @spec terminal_events_for_session_query(String.t()) :: Ecto.Query.t()
  def terminal_events_for_session_query(session_id) when is_binary(session_id) do
    from(event in TerminalEvent,
      where: event.session_id == ^session_id or event.run_id == ^session_id,
      order_by: [asc: event.sequence, asc: event.at]
    )
  end

  @spec terminal_events_for_session(Store.t(), String.t()) :: [TerminalEvent.t()]
  def terminal_events_for_session(%Store{} = store, session_id) do
    SQLite.with_repo(store, fn ->
      store.repo.all(terminal_events_for_session_query(session_id))
    end)
  end

  @spec workflow_runs_for_session_query(String.t()) :: Ecto.Query.t()
  def workflow_runs_for_session_query(session_id) when is_binary(session_id) do
    from(run in WorkflowRun,
      where: run.session_id == ^session_id or run.id == ^session_id,
      order_by: [desc: run.started_at, desc: run.inserted_at]
    )
  end

  @spec workflow_runs_for_session(Store.t(), String.t()) :: [WorkflowRun.t()]
  def workflow_runs_for_session(%Store{} = store, session_id) do
    SQLite.with_repo(store, fn -> store.repo.all(workflow_runs_for_session_query(session_id)) end)
  end

  @spec tool_calls_for_session_query(String.t()) :: Ecto.Query.t()
  def tool_calls_for_session_query(session_id) when is_binary(session_id) do
    from(call in ToolCall,
      where: call.session_id == ^session_id or call.workflow_run_id == ^session_id,
      order_by: [asc: call.requested_at, asc: call.started_at, asc: call.completed_at]
    )
  end

  @spec tool_calls_for_session(Store.t(), String.t()) :: [ToolCall.t()]
  def tool_calls_for_session(%Store{} = store, session_id) do
    SQLite.with_repo(store, fn -> store.repo.all(tool_calls_for_session_query(session_id)) end)
  end

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

  @spec objective_loop_events_query(String.t()) :: Ecto.Query.t()
  def objective_loop_events_query(session_or_run_id) when is_binary(session_or_run_id) do
    from(event in TerminalEvent,
      where:
        (event.run_id == ^session_or_run_id or event.session_id == ^session_or_run_id) and
          event.agent == "rlm" and
          (event.phase == "objective_loop" or
             event.phase == "objective_loop_progress" or
             (event.phase == "objective_loop_resume" and
                event.title == "Objective auto-resume limit reached")),
      order_by: [asc: event.sequence, asc: event.at]
    )
  end

  @spec objective_loop_events(Store.t(), String.t()) :: [TerminalEvent.t()]
  def objective_loop_events(%Store{} = store, session_or_run_id) do
    SQLite.with_repo(store, fn ->
      store.repo.all(objective_loop_events_query(session_or_run_id))
    end)
  end

  @spec latest_objective_loop_state(Store.t(), String.t()) :: map() | nil
  def latest_objective_loop_state(%Store{} = store, session_or_run_id)
      when is_binary(session_or_run_id) do
    store
    |> objective_loop_events(session_or_run_id)
    |> List.last()
    |> objective_loop_state()
  end

  @spec latest_objective_session(Store.t(), String.t()) :: ObjectiveSession.t() | nil
  def latest_objective_session(%Store{} = store, session_or_run_id)
      when is_binary(session_or_run_id) do
    store
    |> objective_loop_events(session_or_run_id)
    |> List.last()
    |> objective_session_from_event()
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

  @spec messages_for_run_query(String.t()) :: Ecto.Query.t()
  def messages_for_run_query(run_id) when is_binary(run_id) do
    conversation_id = "conversation:#{run_id}"

    from(message in AgentMessage,
      where:
        message.presentation_group_id == ^run_id or message.session_id == ^run_id or
          message.conversation_id == ^conversation_id,
      order_by: [asc: message.created_at]
    )
  end

  @spec messages_for_run(Store.t(), String.t()) :: [AgentMessage.t()]
  def messages_for_run(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn ->
      store.repo.all(messages_for_run_query(run_id))
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
      where: request.workflow_run_id == ^run_id or request.session_id == ^run_id,
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

  defp objective_loop_state(nil), do: nil

  defp objective_loop_state(%TerminalEvent{} = event) do
    data = event.data_json || %{}
    session = field(data, :objective_session) || %{}
    state = field(data, :objective_session_state) || %{}

    decision =
      field(data, :objective_decision) ||
        field(session, :decision) ||
        %{
          action: field(data, :action),
          status: field(data, :status) || field(session, :status) || field(state, :status)
        }

    review_requests =
      field(data, :review_requests) || field(session, :review_requests) ||
        field(state, :review_requests) || []

    budget_requests =
      field(data, :budget_requests) || field(session, :budget_requests) ||
        field(state, :budget_requests) || []

    latest_error =
      field(session, :latest_error) ||
        field(state, :latest_error)

    %{
      event_id: event.id,
      session_id: event.session_id,
      run_id: event.run_id,
      sequence: event.sequence,
      at: event.at,
      status: field(session, :status) || field(state, :status) || event.status,
      action:
        field(decision, :action) || field(data, :action) ||
          objective_action_from_status(field(decision, :status)),
      objective: field(session, :objective) || field(state, :objective),
      iteration_count:
        field(data, :objective_iteration_count) ||
          field(data, :iteration_count) ||
          field(data, :current_iteration) ||
          field(session, :iteration_count) ||
          length(field(state, :iterations) || []),
      max_iterations:
        field(session, :max_iterations) || field(data, :max_iterations) ||
          field(state, :max_iterations),
      latest_error: latest_error,
      latest_error_kind: field(latest_error, :kind) || field(session, :latest_error_kind),
      latest_error_message:
        field(latest_error, :message) || field(session, :latest_error_message),
      open_tasks:
        field(data, :open_tasks) || field(session, :open_tasks) || field(state, :open_tasks) ||
          [],
      completed_tasks:
        field(data, :completed_tasks) || field(session, :completed_tasks) ||
          field(state, :completed_tasks) || [],
      review_requests: review_requests,
      pending_review_requests: Enum.filter(review_requests, &pending_review_request?/1),
      latest_review_request:
        field(data, :latest_review_request) || field(session, :latest_review_request) ||
          List.last(review_requests),
      budget_requests: budget_requests,
      pending_budget_requests: Enum.filter(budget_requests, &pending_budget_request?/1),
      decision: decision,
      summary: session,
      title: event.title,
      detail: event.detail
    }
    |> reject_nil_values()
  end

  defp objective_session_from_event(nil), do: nil

  defp objective_session_from_event(%TerminalEvent{} = event) do
    data = event.data_json || %{}

    data
    |> field(:objective_session_state)
    |> case do
      state when is_map(state) ->
        case ObjectiveSession.from_map(state) do
          {:ok, session} -> session
          {:error, _error} -> nil
        end

      _other ->
        nil
    end
  end

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp objective_action_from_status(status)
       when status in [:needs_review_approval, "needs_review_approval"],
       do: "request_review_approval"

  defp objective_action_from_status(status)
       when status in [:needs_budget_approval, "needs_budget_approval"],
       do: "request_budget_approval"

  defp objective_action_from_status(_status), do: nil

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp pending_review_request?(request) when is_map(request) do
    field(request, :status) in [nil, :pending, "pending", :waiting, "waiting"]
  end

  defp pending_review_request?(_request), do: false

  defp pending_budget_request?(request) when is_map(request) do
    field(request, :status) in [nil, :pending, "pending", :waiting, "waiting"]
  end

  defp pending_budget_request?(_request), do: false

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
