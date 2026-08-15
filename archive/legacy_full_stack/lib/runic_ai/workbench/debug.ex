defmodule RunicAI.Workbench.Debug do
  @moduledoc """
  Bounded read-side projections for the Phoenix debug workbench.
  """

  import Ecto.Query

  alias RunicAI.Persistence.Export
  alias RunicAI.Persistence.JSON
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.ManagedWorkflow
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.RunnableEvent
  alias RunicAI.Persistence.Schemas.Scorecard
  alias RunicAI.Persistence.Schemas.TerminalEvent
  alias RunicAI.Persistence.Schemas.WorkflowEvent
  alias RunicAI.Persistence.Schemas.WorkflowFact
  alias RunicAI.Terminal.ExRatatui.PersistenceView
  alias RunicAI.Workbench

  @default_limit 40
  @max_limit 100

  @spec logs(Store.t(), map()) :: map()
  def logs(%Store{} = store, params) do
    filters = filters(params)

    query =
      TerminalEvent
      |> terminal_filters(filters)
      |> order_by([event], asc: event.sequence, asc: event.at)

    page(store, query, filters, &PersistenceView.terminal_event/1)
  end

  @spec traces(Store.t(), map()) :: map()
  def traces(%Store{} = store, params) do
    filters = filters(params)
    run_id = filters.run_id

    %{
      filters: filters,
      terminal: logs(store, params),
      runnable:
        trace_page(store, RunnableEvent, run_id, filters, &PersistenceView.runnable_event/1),
      workflow: trace_page(store, WorkflowEvent, run_id, filters, &workflow_event/1)
    }
  end

  @spec managed_workflows(Store.t(), map()) :: map()
  def managed_workflows(%Store{} = store, params) do
    filters = filters(params)

    query =
      ManagedWorkflow
      |> workflow_filters(filters)
      |> order_by([workflow], asc: workflow.workflow_key)

    page(store, query, filters, &PersistenceView.managed_workflow/1)
  end

  @spec scorecards(Store.t(), map()) :: map()
  def scorecards(%Store{} = store, params) do
    filters = filters(params)

    query =
      Scorecard
      |> scorecard_filters(filters)
      |> order_by([scorecard], desc: scorecard.created_at)

    page(store, query, filters, &PersistenceView.scorecard/1)
  end

  @spec context(Store.t(), map()) :: map()
  def context(%Store{} = store, params) do
    filters = filters(params)
    limit = filters.limit

    if blank?(filters.run_id) do
      %{filters: filters, messages: [], artifacts: [], facts: [], source_cues: []}
    else
      run_id = filters.run_id

      %{
        filters: filters,
        messages:
          take(Queries.messages_for_run(store, run_id), limit, &PersistenceView.message/1),
        artifacts:
          take(Queries.artifacts_for_run(store, run_id), limit, &PersistenceView.artifact/1),
        facts: facts(store, run_id, limit),
        source_cues: source_cues(store, run_id, limit)
      }
    end
  end

  @spec health(Store.t()) :: map()
  def health(%Store{} = store) do
    db_health = Workbench.health()

    counts =
      SQLite.with_repo(store, fn ->
        %{
          sessions: store.repo.aggregate(RunicAI.Persistence.Schemas.AgentSession, :count),
          runs: store.repo.aggregate(RunicAI.Persistence.Schemas.WorkflowRun, :count),
          terminal_events: store.repo.aggregate(TerminalEvent, :count),
          managed_workflows: store.repo.aggregate(ManagedWorkflow, :count),
          scorecards: store.repo.aggregate(Scorecard, :count)
        }
      end)

    Map.merge(db_health, %{counts: counts})
  end

  @spec diagnostics(Store.t()) :: map()
  def diagnostics(%Store{} = store) do
    health = health(store)
    workbench = Application.get_env(:runic_ai, :workbench, [])
    endpoint = Application.get_env(:runic_ai, RunicAIWeb.Endpoint, [])

    %{
      generated_at: DateTime.utc_now(),
      app: %{
        name: "runic_ai",
        version: app_version(),
        elixir: System.version(),
        otp: System.otp_release()
      },
      endpoint:
        JSON.safe(%{
          server?: Keyword.get(endpoint, :server, false),
          http: Keyword.get(endpoint, :http, []),
          url: Keyword.get(endpoint, :url, [])
        }),
      workbench:
        JSON.safe(%{
          data_path: Keyword.get(workbench, :data_path),
          database: Keyword.get(workbench, :database),
          bind_ip: Keyword.get(workbench, :bind_ip),
          bind_port: Keyword.get(workbench, :bind_port),
          auth_required?: Keyword.get(workbench, :auth_required?, false),
          default_agent: Keyword.get(workbench, :default_agent),
          default_model: Keyword.get(workbench, :default_model),
          default_client: Keyword.get(workbench, :default_client),
          default_approval: Keyword.get(workbench, :default_approval),
          default_mode: Keyword.get(workbench, :default_mode),
          theme: Keyword.get(workbench, :theme)
        }),
      health: health
    }
  end

  @spec jsonl(Store.t(), String.t()) :: String.t()
  def jsonl(%Store{} = store, run_id) when is_binary(run_id),
    do: Export.terminal_jsonl(store, run_id)

  defp app_version do
    :runic_ai
    |> Application.spec(:vsn)
    |> case do
      nil -> "dev"
      version -> to_string(version)
    end
  end

  defp trace_page(_store, _schema, nil, filters, _mapper) do
    %{filters: filters, rows: [], page: filters.page, limit: filters.limit, total: 0}
  end

  defp trace_page(store, schema, run_id, filters, mapper) do
    query =
      from(row in schema,
        where: row.run_id == ^run_id,
        order_by: [asc: row.sequence, asc: row.inserted_at]
      )

    page(store, query, filters, mapper)
  end

  defp page(%Store{} = store, query, filters, mapper) do
    offset = (filters.page - 1) * filters.limit

    SQLite.with_repo(store, fn ->
      total = store.repo.one(from(row in subquery(query), select: count()))

      rows =
        query
        |> limit(^filters.limit)
        |> offset(^offset)
        |> store.repo.all()
        |> Enum.map(mapper)

      %{
        filters: filters,
        rows: rows,
        page: filters.page,
        limit: filters.limit,
        total: total || 0
      }
    end)
  end

  defp terminal_filters(query, filters) do
    query
    |> maybe_where(filters.run_id, fn query, value ->
      from(event in query, where: event.run_id == ^value)
    end)
    |> maybe_where(filters.session_id, fn query, value ->
      from(event in query, where: event.session_id == ^value)
    end)
    |> maybe_where(filters.kind, fn query, value ->
      from(event in query, where: event.kind == ^value)
    end)
    |> maybe_where(filters.status, fn query, value ->
      from(event in query, where: event.status == ^value)
    end)
    |> maybe_where(filters.phase, fn query, value ->
      from(event in query, where: event.phase == ^value)
    end)
    |> maybe_search(filters.q)
  end

  defp workflow_filters(query, filters) do
    query
    |> maybe_where(filters.status, fn query, value ->
      from(workflow in query, where: workflow.status == ^value)
    end)
    |> maybe_search(filters.q, [:workflow_key, :workflow_name])
  end

  defp scorecard_filters(query, filters) do
    query
    |> maybe_where(filters.run_id, fn query, value ->
      from(scorecard in query, where: scorecard.run_id == ^value)
    end)
    |> maybe_where(filters.status, fn query, value ->
      from(scorecard in query, where: scorecard.objective_status == ^value)
    end)
  end

  defp maybe_search(query, value), do: maybe_search(query, value, [:title, :detail])

  defp maybe_search(query, value, fields) do
    if blank?(value) do
      query
    else
      pattern = "%#{String.replace(value, "%", "\\%")}%"

      Enum.reduce(fields, nil, fn field, dynamic ->
        clause = dynamic([row], like(field(row, ^field), ^pattern))
        if dynamic, do: dynamic([row], ^dynamic or ^clause), else: clause
      end)
      |> then(fn dynamic -> from(row in query, where: ^dynamic) end)
    end
  end

  defp maybe_where(query, value, fun) when is_function(fun, 2) do
    if blank?(value), do: query, else: fun.(query, value)
  end

  defp filters(params) do
    %{
      run_id: clean(params["run_id"]),
      session_id: clean(params["session_id"]),
      kind: clean(params["kind"]),
      status: clean(params["status"]),
      phase: clean(params["phase"]),
      q: clean(params["q"]),
      page: bounded_int(params["page"], 1, 1, 10_000),
      limit: bounded_int(params["limit"], @default_limit, 1, @max_limit)
    }
  end

  defp bounded_int(value, default, min, max) do
    value
    |> clean()
    |> case do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} -> int |> max(min) |> min(max)
          _other -> default
        end
    end
  end

  defp clean(nil), do: nil

  defp clean(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp take(rows, limit, mapper), do: rows |> Enum.take(limit) |> Enum.map(mapper)

  defp facts(%Store{} = store, run_id, limit) do
    SQLite.with_repo(store, fn ->
      from(fact in WorkflowFact,
        where: fact.run_id == ^run_id,
        order_by: [asc: fact.inserted_at],
        limit: ^limit
      )
      |> store.repo.all()
      |> Enum.map(fn fact ->
        %{
          hash_key: fact.hash_key,
          run_id: fact.run_id,
          producer_node: fact.producer_node,
          component_id: fact.component_id,
          preview: fact.preview_json || %{},
          inserted_at: fact.inserted_at
        }
      end)
    end)
  end

  defp source_cues(%Store{} = store, run_id, limit) do
    SQLite.with_repo(store, fn ->
      event_cues =
        from(event in TerminalEvent,
          where: event.run_id == ^run_id,
          order_by: [asc: event.sequence],
          limit: ^limit
        )
        |> store.repo.all()
        |> Enum.flat_map(&extract_cues(PersistenceView.terminal_event(&1)))

      message_cues =
        from(message in AgentMessage,
          where: message.presentation_group_id == ^run_id or message.session_id == ^run_id,
          order_by: [asc: message.created_at],
          limit: ^limit
        )
        |> store.repo.all()
        |> Enum.flat_map(&extract_cues(PersistenceView.message(&1)))

      artifact_cues =
        from(artifact in RunArtifact,
          where: artifact.run_id == ^run_id,
          order_by: [asc: artifact.inserted_at],
          limit: ^limit
        )
        |> store.repo.all()
        |> Enum.flat_map(&extract_cues(PersistenceView.artifact(&1)))

      (event_cues ++ message_cues ++ artifact_cues)
      |> Enum.uniq()
      |> Enum.take(limit)
    end)
  end

  defp extract_cues(value) do
    value
    |> flatten_values()
    |> Enum.filter(
      &(String.contains?(String.downcase(&1), "source") or
          String.contains?(String.downcase(&1), "cue"))
    )
  end

  defp flatten_values(%{} = map), do: map |> Map.values() |> Enum.flat_map(&flatten_values/1)
  defp flatten_values(list) when is_list(list), do: Enum.flat_map(list, &flatten_values/1)
  defp flatten_values(value) when is_binary(value), do: [value]
  defp flatten_values(value) when is_atom(value), do: [Atom.to_string(value)]
  defp flatten_values(_value), do: []

  defp workflow_event(event) do
    %{
      run_id: event.run_id,
      sequence: event.sequence,
      event_type: event.event_type,
      node_name: event.node_name,
      runnable_id: event.runnable_id,
      component_id: event.component_id,
      component_type: event.component_type,
      payload: event.payload_json || %{},
      inserted_at: event.inserted_at
    }
  end
end
