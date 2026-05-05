defmodule RunicAI.Persistence.ManagedWorkflows do
  @moduledoc """
  Small API for durable, user-invokable workflow definitions.

  A managed workflow is the stable definition keyed by `workflow_key`. Concrete
  executions remain `workflow_runs`, so one command, schedule, or agent-built
  workflow can create many resumable runs over time.
  """

  alias RunicAI.Persistence.JSON
  alias RunicAI.Ids
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.RunnerStore
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.Schemas.ManagedWorkflow
  alias RunicAI.Persistence.Schemas.WorkflowRun

  @spec create(Store.t(), map() | keyword()) :: {:ok, ManagedWorkflow.t()} | {:error, term()}
  def create(%Store{} = store, attrs) when is_list(attrs), do: create(store, Map.new(attrs))

  def create(%Store{} = store, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:status, :active)
      |> Map.put_new(:definition_kind, :term)
      |> maybe_put_definition_blob()

    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        %ManagedWorkflow{}
        |> ManagedWorkflow.changeset(attrs)
        |> store.repo.insert()
      end)
    end)
  end

  @spec update(Store.t(), String.t(), map() | keyword()) ::
          {:ok, ManagedWorkflow.t()} | {:error, term()}
  def update(%Store{} = store, workflow_key_or_id, attrs) when is_list(attrs),
    do: update(store, workflow_key_or_id, Map.new(attrs))

  def update(%Store{} = store, workflow_key_or_id, attrs) when is_binary(workflow_key_or_id) do
    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        case get_by_key_or_id(store, workflow_key_or_id) do
          nil ->
            {:error, :not_found}

          %ManagedWorkflow{} = workflow ->
            attrs =
              attrs
              |> Map.new()
              |> maybe_put_definition_blob()

            workflow
            |> ManagedWorkflow.changeset(attrs)
            |> store.repo.update()
        end
      end)
    end)
  end

  @spec get(Store.t(), String.t()) :: ManagedWorkflow.t() | nil
  def get(%Store{} = store, workflow_key_or_id) when is_binary(workflow_key_or_id) do
    SQLite.with_repo(store, fn -> get_by_key_or_id(store, workflow_key_or_id) end)
  end

  @spec create_run(Store.t(), String.t(), map() | keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def create_run(store, workflow_key, attrs \\ %{})

  def create_run(%Store{} = store, workflow_key, attrs) when is_list(attrs),
    do: create_run(store, workflow_key, Map.new(attrs))

  def create_run(%Store{} = store, workflow_key, attrs) when is_binary(workflow_key) do
    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        store.repo.transaction(fn ->
          case get_by_key_or_id(store, workflow_key) do
            nil ->
              store.repo.rollback(:not_found)

            %ManagedWorkflow{} = workflow ->
              run_id = Map.get(attrs, :id) || Map.get(attrs, "id") || default_run_id(workflow)

              run_attrs = %{
                id: run_id,
                workflow_key: workflow.workflow_key,
                workflow_name: workflow.workflow_name,
                workflow_id_blob: Term.to_blob(run_id),
                managed_workflow_id: workflow.id,
                status: Map.get(attrs, :status, Map.get(attrs, "status", :running)),
                trigger: Map.get(attrs, :trigger, Map.get(attrs, "trigger", :manual)),
                input_blob: input_blob(attrs),
                metadata_json:
                  Map.merge(
                    workflow.metadata_json || %{},
                    JSON.safe(Map.get(attrs, :metadata, %{}))
                  ),
                error_json: %{},
                started_at: Map.get(attrs, :started_at, DateTime.utc_now())
              }

              run =
                %WorkflowRun{}
                |> WorkflowRun.changeset(run_attrs)
                |> store.repo.insert!()

              workflow
              |> ManagedWorkflow.changeset(%{last_run_id: run.id})
              |> store.repo.update!()

              run
          end
        end)
      end)
    end)
    |> case do
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec pending(Store.t()) :: [ManagedWorkflow.t()]
  def pending(%Store{} = store), do: Queries.pending_managed_workflows(store)

  @spec active(Store.t()) :: [ManagedWorkflow.t()]
  def active(%Store{} = store), do: Queries.active_managed_workflows(store)

  @spec failed(Store.t()) :: [ManagedWorkflow.t()]
  def failed(%Store{} = store), do: Queries.failed_managed_workflows(store)

  @spec paused(Store.t()) :: [ManagedWorkflow.t()]
  def paused(%Store{} = store), do: Queries.paused_managed_workflows(store)

  @spec scheduled(Store.t()) :: [ManagedWorkflow.t()]
  def scheduled(%Store{} = store), do: Queries.scheduled_managed_workflows(store)

  @spec resumable(Store.t()) :: [ManagedWorkflow.t()]
  def resumable(%Store{} = store),
    do: Queries.managed_workflows(store, status: [:paused, :failed])

  @spec resume(Store.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def resume(%Store{} = store, workflow_key, opts \\ []) when is_binary(workflow_key) do
    runner = Keyword.fetch!(opts, :runner)
    runner_opts = Keyword.get(opts, :runner_opts, [])

    with %ManagedWorkflow{last_run_id: run_id} when is_binary(run_id) <- get(store, workflow_key),
         {:ok, pid} <- Runic.Runner.resume(runner, run_id, runner_opts) do
      {:ok, pid}
    else
      %ManagedWorkflow{} -> {:error, :no_runs}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec runner_store_opts(Store.t()) :: keyword()
  def runner_store_opts(%Store{} = store), do: [store: store]

  @spec runner_store() :: module()
  def runner_store, do: RunnerStore

  defp get_by_key_or_id(%Store{} = store, workflow_key_or_id) do
    store.repo.get(ManagedWorkflow, workflow_key_or_id) ||
      store.repo.get_by(ManagedWorkflow, workflow_key: workflow_key_or_id)
  end

  defp maybe_put_definition_blob(attrs) do
    case Map.get(attrs, :definition_blob) || Map.get(attrs, "definition_blob") do
      value when is_binary(value) ->
        attrs

      _other ->
        definition = Map.get(attrs, :definition) || Map.get(attrs, "definition")

        if is_nil(definition) do
          attrs
        else
          Map.put(attrs, :definition_blob, Term.to_blob(definition))
        end
    end
  end

  defp default_run_id(%ManagedWorkflow{} = workflow) do
    Ids.unique("run:#{workflow.workflow_key}")
  end

  defp input_blob(attrs) do
    case Map.get(attrs, :input, Map.get(attrs, "input")) do
      nil -> nil
      input -> Term.to_blob(input)
    end
  end
end
