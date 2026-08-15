defmodule RunicAI.Workbench do
  @moduledoc """
  Local workbench API shared by Phoenix LiveViews and future server packaging.

  The durable SQLite store remains the source of truth. This module provides
  bounded query projections and small PubSub invalidations for web surfaces.
  """

  import Ecto.Query, only: [from: 2]

  alias RunicAI.Ids
  alias RunicAI.Agent.CapabilityResolver
  alias RunicAI.Coding.Review
  alias RunicAI.LLM.ModelCatalog
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.ManagedWorkflows
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Persistence.WorkflowExecutor
  alias RunicAI.Persistence.WorkflowTask
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.AgentSession
  alias RunicAI.Persistence.Schemas.ManagedWorkflow
  alias RunicAI.Persistence.Schemas.ReviewRequest
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.Scorecard
  alias RunicAI.Persistence.Schemas.TerminalEvent
  alias RunicAI.Persistence.Schemas.ToolCall
  alias RunicAI.Persistence.Schemas.WorkflowRun
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Event, as: CoreEvent
  alias RunicAI.Error
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest, as: RuntimeReviewRequest
  alias RunicAI.Terminal.AgentRunner
  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.GraphPresenter
  alias RunicAI.Terminal.RLMRunner
  alias RunicAI.Workbench.StoreServer
  alias RunicAI.Workbench.WorkflowRunner
  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Workflows.Compiler, as: WorkflowCompiler
  alias RunicAI.Workflows.Catalog, as: WorkflowCatalog
  alias RunicAI.Workflows.Editor, as: WorkflowEditor
  alias RunicAI.Workflows.IntentPlanner
  alias RunicAI.Workflows.IR, as: WorkflowIR
  alias RunicAI.Workflows.Validator, as: WorkflowValidator

  @topic "runic_ai:workbench"
  @task_supervisor RunicAI.Workbench.TaskSupervisor
  @default_objective_resume_limit 5
  @sandbox_inventory_profiles [
    local_code: [
      backend: :just_bash,
      runtimes: [:bash],
      network: :disabled,
      stateful?: false,
      workspace: [mode: :copy_in, persist?: false],
      pool: [warm: 0, max: 1]
    ],
    lua: [
      backend: :lua,
      runtimes: [:lua],
      network: :disabled,
      stateful?: false,
      workspace: [mode: :copy_in, persist?: false],
      pool: [warm: 0, max: 1]
    ],
    docker: [
      backend: :docker,
      runtimes: [:bash, :python, :node, :elixir, :lua],
      network: :disabled,
      stateful?: true,
      workspace: [mode: :copy_in, persist?: true],
      pool: [warm: 0, max: 2]
    ],
    gvisor: [
      backend: :gvisor,
      runtimes: [:bash, :python, :node, :elixir, :lua],
      network: :disabled,
      stateful?: true,
      workspace: [mode: :copy_in, persist?: true],
      pool: [warm: 0, max: 2]
    ],
    vmsan: [
      backend: :vmsan,
      runtimes: [:bash, :python, :node, :elixir, :lua],
      network: :disabled,
      stateful?: true,
      workspace: [mode: :copy_in, persist?: true],
      pool: [warm: 0, max: 2]
    ],
    sprites: [
      backend: :sprites,
      runtimes: [:bash, :python, :node, :elixir, :lua],
      network: :restricted,
      stateful?: true,
      workspace: [mode: :copy_in, persist?: true],
      pool: [warm: 0, max: 2]
    ]
  ]

  @agent_choices %{"assistant" => :assistant, "standard" => :standard, "rlm" => :rlm}
  @approval_choices %{
    "always" => :always,
    "all" => :always,
    "safe" => :safe,
    "never" => :never,
    "ask" => :ask
  }
  @mode_choices %{"verify" => :verify, "patch" => :patch, "read_only" => :read_only}
  @write_policy_choices %{
    "docs_only" => :docs_only,
    "docs-only" => :docs_only,
    "workspace_review" => :workspace_review,
    "workspace-review" => :workspace_review,
    "none" => :none
  }
  @intent_strategy_choices %{"auto" => :auto, "direct" => :direct, "workflow" => :workflow}
  @review_wait_poll_interval_ms 250
  @rlm_workspace_cues ~w(
    api app branch bug code codebase command compile compiler component config
    dependency deps diff docs ecto elixir endpoint error exception failing failure
    file files fix function git issue lib liveview log logs migration mix module
    patch phoenix pr repo repository route runic runicai schema sqlite stacktrace
    test tests tui warning warnings workspace
  )
  @param_atoms %{
    "action" => :action,
    "agent" => :agent,
    "approve" => :approve,
    "client" => :client,
    "cwd" => :cwd,
    "max_runtime_ms" => :max_runtime_ms,
    "mode" => :mode,
    "model" => :model,
    "model_id" => :model_id,
    "model_provider" => :model_provider,
    "max_objective_iterations" => :max_objective_iterations,
    "objective" => :objective,
    "profile" => :profile,
    "rewrite" => :rewrite,
    "run_id" => :run_id,
    "sandbox_backend" => :sandbox_backend,
    "sandbox_network" => :sandbox_network,
    "sandbox_pool_max" => :sandbox_pool_max,
    "sandbox_pool_warm" => :sandbox_pool_warm,
    "sandbox_profile" => :sandbox_profile,
    "sandbox_runtime" => :sandbox_runtime,
    "sandbox_runtimes" => :sandbox_runtimes,
    "sandbox_stateful" => :sandbox_stateful,
    "session_id" => :session_id,
    "tool_config" => :tool_config,
    "toolsets" => :toolsets,
    "disabled_tools" => :disabled_tools,
    "write_policy" => :write_policy
  }

  @spec store() :: {:ok, Store.t()} | {:error, term()}
  def store, do: StoreServer.store()

  @spec store!() :: Store.t()
  def store!, do: StoreServer.store!()

  @spec resume_workflow_run(String.t()) :: {:ok, map()} | {:error, term()}
  def resume_workflow_run(run_id) when is_binary(run_id) do
    store = store!()

    result =
      case workflow_run(store, run_id) do
        %WorkflowRun{} = run when run.trigger in ["workflow_task", "workflow_task_retry"] ->
          WorkflowTask.resume(store, run_id, runner: WorkflowRunner.runner())

        %WorkflowRun{} ->
          WorkflowExecutor.resume(store, run_id, runner: WorkflowRunner.runner())

        nil ->
          {:error, :not_found}
      end

    case result do
      {:ok, %{run: run}} = result ->
        watch_workflow_run(run)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @spec restart_workflow_child_run(String.t()) :: {:ok, map()} | {:error, term()}
  def restart_workflow_child_run(run_id) when is_binary(run_id) do
    case WorkflowTask.restart(store!(), run_id,
           runner: WorkflowRunner.runner(),
           reason: "human restarted failed child from Workbench"
         ) do
      {:ok, %{run: run}} = result ->
        watch_workflow_run(run)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @spec start_workflow_run(String.t()) :: {:ok, map()} | {:error, term()}
  def start_workflow_run(run_id) when is_binary(run_id) do
    case WorkflowExecutor.start_run(store!(), run_id, runner: WorkflowRunner.runner()) do
      {:ok, %{run: run}} = result ->
        watch_workflow_run(run)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @spec request_workflow_run_review(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def request_workflow_run_review(run_id, attrs \\ %{}) when is_binary(run_id) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:checkpoint, "operator_review")
      |> Map.put_new(:prompt, "Review the pinned workflow run before it continues")

    WorkflowExecutor.pause_for_review(store!(), run_id, attrs, runner: WorkflowRunner.runner())
  end

  defp watch_workflow_run(%WorkflowRun{} = run) do
    Task.Supervisor.start_child(@task_supervisor, fn ->
      store = store!()
      terminal = WorkflowExecutor.await_terminal(store, run.id, timeout: 300_000)

      if run.trigger in ["workflow_task", "workflow_task_retry"] and
           match?({:ok, %WorkflowRun{status: "completed"}}, terminal) do
        _ =
          WorkflowTask.await_result(store, run.id,
            runner: WorkflowRunner.runner(),
            timeout: 1_000
          )
      end

      if root_workflow_run?(run) do
        _ = record_root_workflow_terminal(store, run, terminal)
      end

      Phoenix.PubSub.broadcast(
        RunicAI.PubSub,
        session_topic(run.session_id),
        {:workbench, :workflow_run, run.session_id}
      )
    end)

    :ok
  end

  defp root_workflow_run?(%WorkflowRun{parent_run_id: nil, trigger: trigger}),
    do: trigger in ["intent_reuse", "workbench", "manual", "fork"]

  defp root_workflow_run?(%WorkflowRun{}), do: false

  defp record_root_workflow_terminal(store, run, {:ok, %WorkflowRun{} = terminal}) do
    {kind, phase, status, title} = workflow_terminal_event_identity(terminal.status)

    output =
      case WorkflowExecutor.output(store, terminal.id) do
        {:ok, value} -> value
        {:error, _reason} -> %{}
      end

    record_terminal_event(%{
      id: Ids.unique("terminal_event"),
      session_id: run.session_id,
      run_id: terminal.id,
      agent: :assistant,
      kind: kind,
      phase: phase,
      status: status,
      title: title,
      detail: "Pinned workflow run #{terminal.status}",
      data_json: %{
        workflow_run_id: terminal.id,
        definition_revision: terminal.definition_revision,
        definition_hash: terminal.definition_hash,
        compiled_hash: terminal.compiled_hash,
        output: output,
        trigger: terminal.trigger
      },
      at: DateTime.utc_now()
    })
  end

  defp record_root_workflow_terminal(_store, _run, {:error, _reason}), do: :ok

  defp workflow_terminal_event_identity("completed"),
    do: {:summary, :completed, :ok, "Workflow completed"}

  defp workflow_terminal_event_identity("blocked"),
    do: {:status, :workflow_blocked, :blocked, "Workflow blocked"}

  defp workflow_terminal_event_identity("cancelled"),
    do: {:status, :workflow_cancelled, :blocked, "Workflow cancelled"}

  defp workflow_terminal_event_identity(_status),
    do: {:error, :workflow_failed, :error, "Workflow failed"}

  @spec apply_workflow_operations(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_workflow_operations(run_id, source, opts \\ [])
      when is_binary(run_id) and is_binary(source) and is_list(opts) do
    store = store!()

    with %WorkflowRun{} = run <- workflow_run(store, run_id),
         workflow when not is_nil(workflow) <-
           ManagedWorkflows.get(store, run.managed_workflow_id),
         {:ok, workspace} <- workflow_workspace(store, run) do
      apply_workflow_operations_to_definition(store, workflow, workspace, source, opts)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec apply_workflow_definition_operations(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_workflow_definition_operations(definition_id, session_id, source, opts \\ [])
      when is_binary(definition_id) and is_binary(session_id) and is_binary(source) and
             is_list(opts) do
    store = store!()

    with %ManagedWorkflow{} = workflow <- ManagedWorkflows.get(store, definition_id),
         :ok <- require_session_definition(workflow, session_id),
         {:ok, workspace} <- workflow_workspace(store, session_id) do
      apply_workflow_operations_to_definition(store, workflow, workspace, source, opts)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp apply_workflow_operations_to_definition(store, workflow, workspace, source, opts) do
    with revision when not is_nil(revision) <-
           WorkflowDefinitions.get_revision(store, workflow.latest_revision_id),
         :ok <- require_expected_revision(revision, opts),
         {:ok, operations} <- decode_workflow_operations(source),
         {:ok, base_ir} <- WorkflowIR.from_input(revision.ir_json),
         {:ok, preview} <-
           WorkflowEditor.apply(base_ir, %{
             base_revision: revision.revision,
             base_hash: revision.semantic_hash,
             operations: operations
           }),
         {:ok, compiled} <- WorkflowCompiler.compile(preview.ir, workspace),
         {:ok, revised} <-
           WorkflowDefinitions.revise(store, workflow.id, %{
             base_revision: revision.revision,
             base_hash: revision.semantic_hash,
             operations: operations,
             actor: Keyword.get(opts, :actor, "workbench:human"),
             operation_metadata: Keyword.get(opts, :operation_metadata, %{})
           }),
         true <-
           compiled.semantic_hash == revised.revision.semantic_hash ||
             {:error, :compiled_revision_hash_mismatch},
         {:ok, artifact} <-
           WorkflowDefinitions.record_compilation(store, revised.revision.id, %{
             artifact: compiled,
             compiled_hash: compiled.compiled_hash,
             catalog_hash: revised.revision.catalog_hash,
             source_map: compiled.source_map,
             metadata: %{
               compiled_by: Keyword.get(opts, :actor, "workbench:human"),
               artifact_format: "recompile_from_ir_v1",
               compiled_hash_format: "stable_lowering_v2"
             }
           }) do
      {:ok, %{revision: revised.revision, edit: revised.edit, artifact: artifact}}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec suggest_workflow_operations(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def suggest_workflow_operations(run_id, source, opts \\ [])
      when is_binary(run_id) and is_binary(source) and is_list(opts) do
    store = store!()

    with %WorkflowRun{} = run <- workflow_run(store, run_id),
         workflow when not is_nil(workflow) <-
           ManagedWorkflows.get(store, run.managed_workflow_id),
         revision when not is_nil(revision) <-
           WorkflowDefinitions.get_revision(store, workflow.latest_revision_id),
         {:ok, operations} <- decode_workflow_operations(source),
         {:ok, base_ir} <- WorkflowIR.from_input(revision.ir_json),
         {:ok, preview} <-
           WorkflowEditor.apply(base_ir, %{
             base_revision: revision.revision,
             base_hash: revision.semantic_hash,
             operations: operations
           }),
         {:ok, workspace} <- workflow_workspace(store, run),
         {:ok, compiled} <- WorkflowCompiler.compile(preview.ir, workspace) do
      review_id = Ids.unique("workflow_edit_review")
      suggested_by = Keyword.get(opts, :actor, "workbench:agent")

      event = %{
        id: Ids.unique("terminal_event"),
        session_id: run.session_id,
        run_id: run.session_id,
        agent: :assistant,
        kind: :hitl,
        phase: :review_requested,
        status: :review,
        title: "Workflow edit suggestion",
        detail:
          "Review #{length(operations)} typed operation(s) affecting #{length(preview.affected_nodes)} node(s)",
        data_json: %{
          id: review_id,
          workflow_run_id: run.id,
          kind: :workflow_edit,
          checkpoint: "workflow_edit",
          resume_key: review_id,
          details: %{
            managed_workflow_id: workflow.id,
            workflow_key: workflow.workflow_key,
            base_revision_id: revision.id,
            base_revision: revision.revision,
            base_hash: revision.semantic_hash,
            result_hash: preview.result_hash,
            compiled_hash: compiled.compiled_hash,
            operations: operations,
            affected_nodes: preview.affected_nodes,
            diff: preview.diff,
            rationale: Keyword.get(opts, :rationale),
            suggested_by: suggested_by
          }
        },
        at: DateTime.utc_now()
      }

      with {:ok, _event} <- record_terminal_event(event),
           {:ok, review} <- get_review_request(run.session_id, review_id) do
        {:ok, %{review: review, edit: preview, compiled: compiled}}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec undo_latest_workflow_operations(String.t()) :: {:ok, map()} | {:error, term()}
  def undo_latest_workflow_operations(run_id) when is_binary(run_id) do
    store = store!()

    with %WorkflowRun{} = run <- workflow_run(store, run_id),
         workflow when not is_nil(workflow) <-
           ManagedWorkflows.get(store, run.managed_workflow_id),
         batch when not is_nil(batch) <-
           store
           |> WorkflowDefinitions.operation_batches(workflow.id)
           |> List.last(),
         true <-
           batch.result_revision_id == workflow.latest_revision_id ||
             {:error, :latest_revision_has_no_undo_batch},
         inverse when is_list(inverse) and inverse != [] <-
           Map.get(batch.data_json || %{}, "inverse_operations") ||
             Map.get(batch.data_json || %{}, :inverse_operations) do
      apply_workflow_operations(run_id, Jason.encode!(inverse))
    else
      nil -> {:error, :not_found}
      false -> {:error, :inverse_operations_unavailable}
      [] -> {:error, :inverse_operations_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @spec compare_workflow_revisions(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def compare_workflow_revisions(run_id, from_revision_id, to_revision_id)
      when is_binary(run_id) and is_binary(from_revision_id) and is_binary(to_revision_id) do
    store = store!()

    with true <- from_revision_id != to_revision_id || {:error, :same_revision},
         %WorkflowRun{} = run <- workflow_run(store, run_id),
         true <- is_binary(run.managed_workflow_id) || {:error, :not_revisioned},
         workflow when not is_nil(workflow) <-
           ManagedWorkflows.get(store, run.managed_workflow_id),
         revisions = WorkflowDefinitions.revisions(store, workflow.id),
         revisions_by_id = Map.new(revisions, &{&1.id, &1}),
         from when not is_nil(from) <- Map.get(revisions_by_id, from_revision_id),
         to when not is_nil(to) <- Map.get(revisions_by_id, to_revision_id),
         {:ok, diff} <- WorkflowEditor.diff(from.ir_json, to.ir_json) do
      {:ok,
       %{
         workflow_id: workflow.id,
         from: workflow_revision_view(from),
         to: workflow_revision_view(to),
         diff: diff
       }}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec workflow_definition_action(String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def workflow_definition_action(run_id, action)
      when is_binary(run_id) and
             action in [
               :request_review,
               :approve,
               :activate,
               :revalidate,
               :migrate_catalog,
               :archive
             ] do
    store = store!()

    with %WorkflowRun{} = run <- workflow_run(store, run_id) do
      apply_workflow_definition_action(store, run.managed_workflow_id, action,
        actor: "workbench:human",
        session_id: run.session_id
      )
    else
      nil -> {:error, :not_found}
    end
  end

  @spec workflow_definition_action_by_id(String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def workflow_definition_action_by_id(definition_id, action, opts \\ [])
      when is_binary(definition_id) and
             action in [
               :request_review,
               :approve,
               :activate,
               :revalidate,
               :migrate_catalog,
               :archive
             ] and
             is_list(opts) do
    apply_workflow_definition_action(
      store!(),
      definition_id,
      action,
      Keyword.put_new(opts, :actor, "workbench:human")
    )
  end

  @spec launch_workflow_definition(String.t(), String.t()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def launch_workflow_definition(definition_id, session_id)
      when is_binary(definition_id) and is_binary(session_id) do
    store = store!()

    with %ManagedWorkflow{} = workflow <- ManagedWorkflows.get(store, definition_id),
         :ok <- require_session_definition(workflow, session_id),
         revision when not is_nil(revision) <-
           WorkflowDefinitions.get_revision(store, workflow.active_revision_id) do
      planning = field(revision.metadata_json || %{}, :planning) || %{}
      input = field(planning, :request) || %{}

      WorkflowDefinitions.launch(store, definition_id, %{
        session_id: session_id,
        status: :pending,
        trigger: :workbench,
        input: input,
        metadata: %{launched_from: "workflow_definition_review"}
      })
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp apply_workflow_definition_action(store, definition_id, action, opts) do
    case action do
      :request_review -> WorkflowDefinitions.request_review(store, definition_id, opts)
      :approve -> WorkflowDefinitions.approve(store, definition_id, opts)
      :activate -> WorkflowDefinitions.activate(store, definition_id, opts)
      :revalidate -> WorkflowDefinitions.revalidate(store, definition_id, opts)
      :migrate_catalog -> migrate_workflow_catalog(store, definition_id, opts)
      :archive -> WorkflowDefinitions.archive(store, definition_id, opts)
    end
  end

  defp migrate_workflow_catalog(store, definition_id, opts) do
    session_id = Keyword.get(opts, :session_id)

    with %ManagedWorkflow{} = workflow <- ManagedWorkflows.get(store, definition_id),
         :ok <- require_session_definition(workflow, session_id),
         {:ok, preview} <- WorkflowDefinitions.catalog_migration_preview(store, workflow.id),
         {:ok, workspace} <- workflow_workspace(store, session_id),
         {:ok, compiled} <- WorkflowCompiler.compile(preview.ir, workspace),
         true <-
           compiled.semantic_hash == preview.semantic_hash ||
             {:error, :compiled_migration_hash_mismatch},
         {:ok, migrated} <-
           WorkflowDefinitions.migrate_catalog(store, workflow.id, %{
             base_revision_id: preview.base_revision.id,
             base_hash: preview.base_revision.semantic_hash,
             expected_semantic_hash: preview.semantic_hash,
             artifact: compiled,
             compiled_hash: compiled.compiled_hash,
             source_map: compiled.source_map,
             actor: Keyword.get(opts, :actor, "workbench:human"),
             artifact_metadata: %{compiled_by: Keyword.get(opts, :actor, "workbench:human")}
           }) do
      {:ok, migrated}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec fork_workflow_run_to_latest(String.t()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def fork_workflow_run_to_latest(run_id) when is_binary(run_id) do
    store = store!()

    with %WorkflowRun{} = run <- workflow_run(store, run_id),
         workflow when not is_nil(workflow) <-
           ManagedWorkflows.get(store, run.managed_workflow_id),
         true <-
           workflow.latest_revision_id != run.definition_revision_id ||
             {:error, :already_on_latest_revision} do
      WorkflowDefinitions.fork_run(store, run.id, workflow.latest_revision_id, %{
        session_id: run.session_id,
        reason: "human selected latest revision in Workbench"
      })
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec health() :: map()
  def health do
    StoreServer.health()
    |> Map.put(:sandbox, sandbox_health())
  end

  @spec sandbox_status() :: map()
  def sandbox_status, do: sandbox_health()

  @spec config() :: keyword()
  def config, do: Application.get_env(:runic_ai, :workbench, [])

  defp sandbox_health do
    profiles = sandbox_inventory_profiles()
    manager = sandbox_manager_status()

    sandboxes =
      Map.new(profiles, fn {name, profile} ->
        direct = direct_sandbox_status(profile)
        managed = manager |> field(:sandboxes) |> field(name)

        {name, sandbox_inventory_status(profile, direct, managed)}
      end)

    %{
      status: if(map_size(sandboxes) == 0, do: :unavailable, else: :available),
      manager: Map.take(manager, [:status, :reason]),
      sandboxes: sandboxes
    }
  rescue
    exception -> %{status: :unavailable, reason: Exception.message(exception), sandboxes: %{}}
  end

  defp sandbox_inventory_profiles do
    (@sandbox_inventory_profiles ++ configured_sandbox_profiles())
    |> Enum.reduce(%{}, fn {name, profile_config}, acc ->
      case sandbox_inventory_profile_name(name) do
        nil ->
          acc

        name ->
          case LitterBox.Profile.from_named_config(name, profile_config) do
            {:ok, profile} -> Map.put(acc, profile.name, profile)
            {:error, _error} -> acc
          end
      end
    end)
  end

  defp sandbox_inventory_profile_name(name) when is_atom(name), do: name

  defp sandbox_inventory_profile_name(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp sandbox_inventory_profile_name(_name), do: nil

  defp configured_sandbox_profiles do
    :runic_ai
    |> Application.get_env(:sandbox, [])
    |> case do
      config when is_list(config) -> Keyword.get(config, :sandboxes, [])
      %{} = config -> Map.get(config, :sandboxes, Map.get(config, "sandboxes", []))
      _other -> []
    end
    |> case do
      profiles when is_list(profiles) -> profiles
      profiles when is_map(profiles) -> Map.to_list(profiles)
      _other -> []
    end
  end

  defp sandbox_manager_status do
    case Process.whereis(RunicAI.Sandbox) do
      nil ->
        %{status: :not_started, reason: :not_started, sandboxes: %{}}

      _pid ->
        case LitterBox.status(server: RunicAI.Sandbox) do
          {:ok, status} ->
            status
            |> sandbox_health_output()
            |> Map.put(:status, :running)

          {:error, error} ->
            %{status: :unavailable, reason: sandbox_error_reason(error), sandboxes: %{}}
        end
    end
  rescue
    exception -> %{status: :unavailable, reason: Exception.message(exception), sandboxes: %{}}
  end

  defp direct_sandbox_status(profile) do
    case LitterBox.status(profile: profile) do
      {:ok, status} -> sandbox_health_output(status)
      {:error, error} -> %{status: :unavailable, reason: sandbox_error_reason(error)}
    end
  rescue
    exception -> %{status: :unavailable, reason: Exception.message(exception)}
  end

  defp sandbox_inventory_status(profile, direct, managed) do
    profile_status = field(direct, :profile) || sandbox_profile_snapshot(profile)
    pool_status = field(managed, :pool_status) || empty_pool_status(profile)
    sessions = field(managed, :sessions) || []
    backend_health = direct |> field(:backends) |> List.wrap() |> List.first() || %{}
    available? = field(direct, :status) in [:available, "available"]
    active? = is_map(managed)
    warm_ready = field(pool_status, :ready) || 0
    busy = field(pool_status, :busy) || 0

    readiness =
      cond do
        warm_ready > 0 -> :ready
        busy > 0 -> :busy
        available? -> :cold
        true -> :unavailable
      end

    profile_status
    |> Map.merge(%{
      backend_health: backend_health,
      status: field(direct, :status) || :unknown,
      readiness: readiness,
      status_label: sandbox_readiness_label(readiness),
      status_detail: sandbox_readiness_detail(readiness, active?, pool_status, direct),
      active?: active?,
      selectable?: available?,
      reason: field(direct, :reason),
      pool_status: pool_status,
      sessions: sessions
    })
  end

  defp sandbox_profile_snapshot(%LitterBox.Profile{} = profile) do
    %{
      name: profile.name,
      backend: profile.backend,
      runtimes: profile.runtimes,
      isolation_level: profile.isolation_level,
      network: profile.policy.network,
      stateful?: profile.stateful?,
      workspace: profile.workspace,
      pool: profile.pool,
      metadata: profile.metadata
    }
    |> sandbox_health_output()
  end

  defp empty_pool_status(%LitterBox.Profile{} = profile) do
    %{
      warm: profile.pool.warm,
      max: profile.pool.max,
      total: 0,
      ready: 0,
      busy: 0,
      stale: 0,
      unhealthy: 0,
      available_capacity: profile.pool.max
    }
  end

  defp sandbox_readiness_label(:ready), do: "Ready"
  defp sandbox_readiness_label(:busy), do: "Busy"
  defp sandbox_readiness_label(:cold), do: "Starts on demand"
  defp sandbox_readiness_label(:unavailable), do: "Needs setup"

  defp sandbox_readiness_detail(:ready, true, pool_status, _direct) do
    ready = field(pool_status, :ready) || 0
    total = field(pool_status, :total) || 0
    "#{ready}/#{total} warm sessions ready"
  end

  defp sandbox_readiness_detail(:busy, true, pool_status, _direct) do
    busy = field(pool_status, :busy) || 0
    "All warm sessions are checked out (#{busy} busy)"
  end

  defp sandbox_readiness_detail(:cold, true, _pool_status, _direct),
    do: "Backend manager is running; this profile will open cold"

  defp sandbox_readiness_detail(:cold, false, _pool_status, _direct),
    do: "Backend is usable and will start when selected"

  defp sandbox_readiness_detail(:unavailable, _active?, _pool_status, direct) do
    case field(direct, :reason) do
      nil -> "Host requirements or credentials are missing"
      reason -> to_string(reason)
    end
  end

  defp sandbox_error_reason(%{message: message}) when is_binary(message), do: message
  defp sandbox_error_reason(error), do: error

  defp sandbox_health_output(%_struct{} = value),
    do: value |> Map.from_struct() |> sandbox_health_output()

  defp sandbox_health_output(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, sandbox_health_output(nested)} end)
  end

  defp sandbox_health_output(value) when is_list(value),
    do: Enum.map(value, &sandbox_health_output/1)

  defp sandbox_health_output(value), do: value

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(RunicAI.PubSub, @topic)

  @spec subscribe_session(String.t()) :: :ok | {:error, term()}
  def subscribe_session(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(RunicAI.PubSub, session_topic(session_id))
  end

  @spec broadcast_terminal_event(TerminalEvent.t()) :: :ok
  def broadcast_terminal_event(%TerminalEvent{} = event) do
    :ok = event |> core_event_from_persisted() |> broadcast_event()

    Phoenix.PubSub.broadcast(RunicAI.PubSub, @topic, {:workbench, :terminal_event, event})

    if is_binary(event.session_id) do
      Phoenix.PubSub.broadcast(
        RunicAI.PubSub,
        session_topic(event.session_id),
        {:workbench, :terminal_event, event}
      )
    end

    :ok
  end

  @spec broadcast_event(CoreEvent.t()) :: :ok
  def broadcast_event(%CoreEvent{} = event) do
    Phoenix.PubSub.broadcast(RunicAI.PubSub, @topic, {:workbench, :event, event})

    if is_binary(event.session_id) do
      Phoenix.PubSub.broadcast(
        RunicAI.PubSub,
        session_topic(event.session_id),
        {:workbench, :event, event}
      )
    end

    :ok
  end

  @spec record_event(map() | CoreEvent.t() | RunicAI.Terminal.Event.t()) ::
          {:ok, TerminalEvent.t()} | {:error, term()}
  def record_event(event) do
    with {:ok, %Store{} = store} <- store(),
         {:ok, %TerminalEvent{} = persisted} <- SQLite.record_terminal_event(store, event) do
      broadcast_terminal_event(persisted)
      {:ok, persisted}
    end
  end

  @spec record_terminal_event(map() | CoreEvent.t() | RunicAI.Terminal.Event.t()) ::
          {:ok, TerminalEvent.t()} | {:error, term()}
  def record_terminal_event(event), do: record_event(event)

  @spec recent_sessions(keyword()) :: [map()]
  def recent_sessions(opts \\ []) do
    store!()
    |> Queries.recent_sessions(opts)
    |> Enum.map(&session_view/1)
  end

  @spec recent_session_summaries(keyword()) :: [map()]
  def recent_session_summaries(opts \\ []) do
    store!()
    |> Queries.recent_sessions(opts)
    |> Enum.map(&session_summary_view/1)
  end

  @spec session_snapshot(String.t()) :: map() | nil
  def session_snapshot(session_id) when is_binary(session_id) do
    store = store!()

    with %AgentSession{} = session <- Queries.get_session(store, session_id) do
      messages =
        store
        |> Queries.messages_for_session(session_id)
        |> visible_chat_messages()

      events = Queries.terminal_events_for_session(store, session_id)
      tools = Queries.tool_calls_for_session(store, session_id)
      runs = Queries.workflow_runs_for_session(store, session_id)
      reviews = Queries.review_requests(store, session_id)
      artifacts = Queries.artifacts_for_run(store, session_id)
      scorecards = Queries.scorecards_for_run(store, session_id)
      workflow_definitions = workflow_definitions_for_session(store, session_id)
      objective_loop = Queries.latest_objective_loop_state(store, session_id)
      event_views = Enum.map(events, &event_view/1)
      sandbox_execution_views = sandbox_execution_views(event_views)
      child_repair_views = child_repair_views(event_views)
      message_views = Enum.map(messages, &message_view/1)
      review_views = Enum.map(reviews, &review_request_view/1)
      artifact_views = Enum.map(artifacts, &artifact_view/1)
      scorecard_views = Enum.map(scorecards, &scorecard_view/1)
      objective_contract = objective_contract_view(events, messages, scorecard_views)
      blocked_evidence = blocked_evidence_view(session, events, messages, scorecard_views)

      completion_proof =
        completion_proof_view(
          session,
          message_views,
          event_views,
          sandbox_execution_views,
          child_repair_views,
          review_views,
          artifact_views,
          scorecard_views,
          objective_contract
        )

      %{
        session: session_view(session),
        capability_profile: capability_profile_view(session, runs, events),
        messages: message_views,
        events: event_views,
        sandbox_executions: sandbox_execution_views,
        child_repairs: child_repair_views,
        tool_calls: Enum.map(tools, &tool_call_view/1),
        runs: Enum.map(runs, &run_view(store, &1)),
        workflow_definitions:
          Enum.map(workflow_definitions, &workflow_definition_view(store, &1)),
        review_requests: review_views,
        artifacts: artifact_views,
        scorecards: scorecard_views,
        objective_loop: objective_loop,
        objective_contract: objective_contract,
        blocked_evidence: blocked_evidence,
        completion_proof: completion_proof,
        plan_workflow_graph: plan_workflow_graph_view(event_views),
        progress_summary: progress_summary_view(session, event_views, blocked_evidence),
        metrics: %{
          messages: length(messages),
          events: length(events),
          sandbox_executions: length(sandbox_execution_views),
          child_repairs: length(child_repair_views),
          tool_calls: length(tools),
          runs: length(runs),
          workflow_definitions: length(workflow_definitions),
          review_requests: length(reviews),
          artifacts: length(artifacts),
          scorecards: length(scorecards)
        }
      }
    end
  end

  @spec latest_objective_session(String.t()) :: RunicAI.Coding.RLM.ObjectiveSession.t() | nil
  def latest_objective_session(session_id) when is_binary(session_id) do
    store!()
    |> Queries.latest_objective_session(session_id)
  end

  @spec first_pending_review_session_id(keyword()) :: String.t() | nil
  def first_pending_review_session_id(opts \\ []) do
    limit = Keyword.get(opts, :limit, 40)
    store = store!()

    store
    |> Queries.recent_sessions(limit: limit)
    |> Enum.find_value(fn %AgentSession{id: session_id} ->
      if pending_review_requests(store, session_id) == [] do
        nil
      else
        session_id
      end
    end)
  end

  @spec start_agent_run(map()) :: {:ok, map()} | {:error, term()}
  def start_agent_run(params) when is_map(params) do
    with {:ok, launch} <- normalize_launch(params) do
      launch = Map.put(launch, :conversation_history, conversation_history(launch))

      with {:ok, %TerminalEvent{}} <- record_terminal_event(user_message_event(launch)),
           {:ok, %TerminalEvent{}} <- record_terminal_event(launch_event(launch)),
           {:ok, %TerminalEvent{}} <- record_terminal_event(capability_profile_event(launch)),
           {:ok, pid} <- start_agent_task(launch) do
        {:ok, %{session_id: launch.session_id, run_id: launch.run_id, pid: pid}}
      end
    end
  end

  @spec start_workflow_intent(map()) :: {:ok, map()} | {:error, term()}
  def start_workflow_intent(params) when is_map(params) do
    with {:ok, launch} <- normalize_launch(params),
         {:ok, intent} <- normalize_workflow_intent(params, launch) do
      launch = Map.put(launch, :conversation_history, conversation_history(launch))

      with {:ok, %TerminalEvent{}} <- record_terminal_event(user_message_event(launch)),
           {:ok, %TerminalEvent{}} <- record_terminal_event(launch_event(launch)),
           {:ok, %TerminalEvent{}} <- record_terminal_event(capability_profile_event(launch)),
           {:ok, pid} <- start_workflow_intent_task(launch, intent) do
        {:ok, %{session_id: launch.session_id, run_id: launch.run_id, pid: pid}}
      end
    end
  end

  @spec record_review_decision(String.t(), String.t(), map()) ::
          {:ok, TerminalEvent.t()} | {:error, term()}
  def record_review_decision(session_id, review_id, params)
      when is_binary(session_id) and is_binary(review_id) and is_map(params) do
    with {:ok, %ReviewRequest{} = review} <- get_review_request(session_id, review_id),
         :ok <- require_pending_review_decision(review),
         {:ok, decision} <- normalize_review_decision(params),
         {:ok, decision} <- maybe_apply_suggested_workflow_edit(review, decision),
         {:ok, definition_decision} <- maybe_decide_definition_review(review, decision),
         {:ok, runtime_decision} <- maybe_decide_runtime_workflow_review(review, decision) do
      agent = review_decision_agent(session_id)

      with {:ok, %TerminalEvent{} = event} <-
             record_terminal_event(review_decision_event(session_id, review, decision, agent)) do
        maybe_start_objective_operator_resume(session_id, review, decision)
        maybe_resume_definition_workflow(review, definition_decision)
        maybe_resume_runtime_workflow(review, runtime_decision)
        {:ok, event}
      end
    end
  end

  defp maybe_apply_suggested_workflow_edit(
         %ReviewRequest{kind: "workflow_edit", workflow_run_id: run_id} = review,
         %{action: action} = decision
       )
       when is_binary(run_id) and action in ["approve", "rewrite"] do
    details = review.details_json || %{}

    source =
      case action do
        "rewrite" -> Map.get(decision, :edited_value)
        "approve" -> Jason.encode!(field(details, :operations) || [])
      end

    with {:ok, result} <-
           apply_workflow_operations(run_id, source,
             actor: "workbench:human:accepted_suggestion",
             expected_revision_id: field(details, :base_revision_id),
             expected_hash: field(details, :base_hash),
             operation_metadata: %{
               suggestion_review_id: review.id,
               suggested_by: field(details, :suggested_by),
               rationale: field(details, :rationale)
             }
           ) do
      {:ok,
       Map.merge(decision, %{
         applied_revision_id: result.revision.id,
         applied_revision: result.revision.revision,
         applied_semantic_hash: result.revision.semantic_hash
       })}
    end
  end

  defp maybe_apply_suggested_workflow_edit(
         %ReviewRequest{kind: "workflow_edit"},
         %{action: action} = decision
       )
       when action in ["deny", "stop"],
       do: {:ok, Map.put(decision, :suggestion_disposition, "rejected")}

  defp maybe_apply_suggested_workflow_edit(%ReviewRequest{}, decision), do: {:ok, decision}

  defp maybe_decide_definition_review(
         %ReviewRequest{kind: "workflow_revision", details_json: details},
         %{action: action} = decision
       )
       when action in ["approve", "rewrite", "deny", "stop"] do
    workflow_id = field(details || %{}, :managed_workflow_id)

    result =
      if action in ["approve", "rewrite"] do
        WorkflowDefinitions.approve(store!(), workflow_id,
          actor: "workbench:human",
          reason: Map.get(decision, :edited_value)
        )
      else
        WorkflowDefinitions.reject(store!(), workflow_id,
          actor: "workbench:human",
          reason: Map.get(decision, :edited_value)
        )
      end

    case result do
      {:ok, lifecycle} -> {:ok, lifecycle}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_decide_definition_review(%ReviewRequest{}, _decision),
    do: {:ok, :not_definition}

  defp maybe_decide_runtime_workflow_review(
         %ReviewRequest{kind: "workflow_run", workflow_run_id: run_id},
         %{action: action} = decision
       )
       when is_binary(run_id) and action in ["approve", "deny", "stop"] do
    status = if action == "approve", do: :approved, else: :denied

    case WorkflowExecutor.decide_review(store!(), run_id, status,
           actor: "workbench:human",
           reason: Map.get(decision, :edited_value)
         ) do
      {:ok, _result} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_decide_runtime_workflow_review(_review, _decision), do: {:ok, :not_runtime}

  defp maybe_resume_runtime_workflow(
         %ReviewRequest{workflow_run_id: run_id},
         :approved
       )
       when is_binary(run_id) do
    resume_workflow_run(run_id)
  end

  defp maybe_resume_runtime_workflow(_review, _decision), do: :ok

  defp maybe_resume_definition_workflow(_review, _decision), do: :ok

  @spec record_approval_policy(String.t(), map()) ::
          {:ok, %{policy: atom(), approved_count: non_neg_integer()}} | {:error, term()}
  def record_approval_policy(session_id, params) when is_binary(session_id) and is_map(params) do
    with {:ok, policy} <- normalize_approval_policy(params),
         {:ok, _session} <- persist_session_approval_policy(session_id, policy) do
      approved_count =
        if policy == :always do
          approve_pending_reviews(session_id, params)
        else
          0
        end

      {:ok, %{policy: policy, approved_count: approved_count}}
    end
  end

  defp require_pending_review_decision(%ReviewRequest{status: status})
       when status in ["pending", "waiting", "review"],
       do: :ok

  defp require_pending_review_decision(%ReviewRequest{}), do: {:error, :review_already_decided}

  defp review_decision_agent(session_id) do
    store!()
    |> Queries.get_session(session_id)
    |> case do
      %AgentSession{agent_kind: agent} when is_binary(agent) and agent != "" -> agent
      _other -> :assistant
    end
  end

  defp normalize_approval_policy(params) do
    policy = params |> value("policy") |> to_string()

    case choice(policy, @approval_choices, nil) do
      {:ok, nil} -> {:error, :invalid_approval_policy}
      result -> result
    end
  end

  defp persist_session_approval_policy(session_id, policy)
       when policy in [:always, :ask, :safe, :never] do
    store = store!()

    SQLite.with_repo(store, fn ->
      case store.repo.get(AgentSession, session_id) do
        %AgentSession{} = session ->
          metadata =
            session.metadata_json
            |> normalize_metadata()
            |> Map.put("approval", Atom.to_string(policy))
            |> Map.put("runtime_approval", Atom.to_string(policy))

          session
          |> AgentSession.changeset(%{metadata_json: metadata})
          |> store.repo.update()

        nil ->
          {:error, :session_not_found}
      end
    end)
  end

  defp approve_pending_reviews(session_id, params) do
    decision_params =
      params
      |> Map.put("action", "approve")
      |> Map.put("source", "session_approval_policy")

    store = store!()

    store
    |> pending_review_requests(session_id)
    |> Enum.reject(&budget_review_request?/1)
    |> Enum.count(fn %ReviewRequest{id: review_id} ->
      match?(
        {:ok, %TerminalEvent{}},
        record_review_decision(session_id, review_id, decision_params)
      )
    end)
  end

  defp budget_review_request?(%ReviewRequest{kind: kind, checkpoint: checkpoint}) do
    kind in ["objective_budget_approval", :objective_budget_approval] or
      checkpoint in ["budget_approval", :budget_approval]
  end

  defp current_session_approval_policy(session_id) do
    store = store!()

    case Queries.get_session(store, session_id) do
      %AgentSession{metadata_json: metadata} ->
        metadata = normalize_metadata(metadata)
        normalize_approval_value(metadata["runtime_approval"] || metadata["approval"])

      _other ->
        nil
    end
  end

  defp normalize_approval_value(value) when value in [:always, :ask, :safe, :never], do: value
  defp normalize_approval_value("always"), do: :always
  defp normalize_approval_value("all"), do: :always
  defp normalize_approval_value("ask"), do: :ask
  defp normalize_approval_value("safe"), do: :safe
  defp normalize_approval_value("never"), do: :never
  defp normalize_approval_value(_value), do: nil

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_metadata(_metadata), do: %{}

  defp normalize_launch(params) do
    cfg = config()

    objective =
      params
      |> value("objective")
      |> to_string()
      |> String.trim()

    with :ok <- require_objective(objective),
         {:ok, agent} <-
           choice(
             value(params, "agent"),
             @agent_choices,
             Keyword.get(cfg, :default_agent, :assistant)
           ),
         {:ok, approve} <-
           choice(
             value(params, "approve"),
             @approval_choices,
             Keyword.get(cfg, :default_approval, :safe)
           ),
         {:ok, mode} <-
           choice(value(params, "mode"), @mode_choices, Keyword.get(cfg, :default_mode, :verify)),
         {:ok, write_policy} <-
           choice(
             value(params, "write_policy"),
             @write_policy_choices,
             Keyword.get(cfg, :default_write_policy, default_write_policy(mode))
           ),
         {:ok, cwd} <- normalize_cwd(value(params, "cwd") || File.cwd!()),
         {:ok, {agent, agent_route}} <- {:ok, route_agent(agent, objective, mode)},
         {:ok, profile} <-
           normalize_profile(
             value(params, "profile") || Keyword.get(cfg, :default_profile, :local_workbench)
           ),
         {:ok, toolsets} <- normalize_list(value(params, "toolsets")),
         {:ok, disabled_tools} <- normalize_list(value(params, "disabled_tools")),
         {:ok, tool_config} <- normalize_tool_config(value(params, "tool_config")),
         {:ok, tool_config} <- normalize_sandbox_tool_config(tool_config, params),
         {:ok, capability_resolution} <-
           CapabilityResolver.resolve(cwd,
             agent: agent,
             mode: mode,
             profile: profile,
             toolsets: toolsets,
             disabled_tools: disabled_tools,
             tool_config: tool_config,
             approval: approve,
             write_policy: write_policy
           ),
         {:ok, max_runtime_ms} <-
           normalize_max_runtime(
             value(params, "max_runtime_ms") || Keyword.get(cfg, :max_runtime_ms, 300_000)
           ),
         {:ok, max_objective_iterations} <-
           normalize_max_objective_iterations(
             value(params, "max_objective_iterations") ||
               Keyword.get(cfg, :max_objective_iterations, 3)
           ) do
      session_id = value(params, "session_id") || Ids.unique("web-session")
      run_id = value(params, "run_id") || Ids.unique("#{agent}:web")
      capability_profile = capability_resolution.metadata
      sandbox = sandbox_launch_summary(tool_config, capability_profile)
      model = normalize_model_selection(params, cfg)

      {:ok,
       %{
         session_id: session_id,
         run_id: run_id,
         objective: objective,
         agent: agent,
         agent_route: agent_route,
         cwd: cwd,
         model: model,
         client: blank_to_nil(value(params, "client") || Keyword.get(cfg, :default_client)),
         approve: approve,
         mode: mode,
         write_policy: write_policy,
         profile: profile,
         toolsets: toolsets,
         disabled_tools: disabled_tools,
         tool_config: tool_config,
         sandbox: sandbox,
         capability_profile: capability_profile,
         run_fun: Keyword.get(cfg, :run_fun),
         max_runtime_ms: max_runtime_ms,
         max_objective_iterations: max_objective_iterations
       }}
    end
  end

  defp normalize_workflow_intent(params, launch) do
    with {:ok, strategy} <-
           choice(value(params, "orchestration"), @intent_strategy_choices, :auto),
         {:ok, input_paths} <- normalize_list(value(params, "input_paths")),
         {:ok, required_sections} <- normalize_list(value(params, "required_sections")) do
      output_path = params |> value("output_path") |> blank_to_nil()

      {:ok,
       %{
         strategy: strategy,
         request: %{
           objective: launch.objective,
           input_paths: input_paths,
           output_path: output_path,
           required_sections: required_sections,
           metadata: %{
             source: "phoenix_workbench",
             session_id: launch.session_id,
             run_id: launch.run_id
           }
         }
       }}
    end
  end

  defp route_agent(:rlm, _objective, :patch), do: {:rlm, nil}

  defp route_agent(:rlm, objective, _mode) do
    if workspace_objective?(objective) do
      {:rlm, nil}
    else
      {:assistant,
       %{
         requested_agent: :rlm,
         routed_agent: :assistant,
         route_reason: :non_workspace_rlm_objective
       }}
    end
  end

  defp route_agent(:assistant, objective, _mode) do
    if local_command_objective?(objective) do
      {:standard,
       %{
         requested_agent: :assistant,
         routed_agent: :standard,
         route_reason: :local_command_objective
       }}
    else
      {:assistant, nil}
    end
  end

  defp route_agent(agent, _objective, _mode), do: {agent, nil}

  defp local_command_objective?(objective) when is_binary(objective) do
    objective = String.downcase(objective)

    (String.contains?(objective, "command") or
       String.contains?(objective, "terminal") or
       String.contains?(objective, "shell") or
       String.contains?(objective, "cli")) and
      Regex.match?(~r/(^|[^a-z0-9_])(run|execute|invoke|call)([^a-z0-9_]|$)/, objective)
  end

  defp workspace_objective?(objective) when is_binary(objective) do
    objective = String.downcase(objective)

    Enum.any?(@rlm_workspace_cues, fn cue ->
      Regex.match?(~r/(^|[^a-z0-9_])#{Regex.escape(cue)}([^a-z0-9_]|$)/, objective)
    end)
  end

  defp start_agent_task(launch) do
    fun = fn -> run_agent(launch) end

    case Process.whereis(@task_supervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(@task_supervisor, fun)
    end
  end

  defp start_workflow_intent_task(launch, intent) do
    fun = fn -> run_workflow_intent_with_deadline(launch, intent) end

    case Process.whereis(@task_supervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(@task_supervisor, fun)
    end
  end

  defp run_workflow_intent_with_deadline(launch, intent) do
    caller = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(caller, {tag, run_workflow_intent(launch, intent)})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        record_workflow_intent_failure(launch, reason)
    after
      launch.max_runtime_ms ->
        failure =
          record_workflow_intent_failure(
            launch,
            Error.timeout("Workflow planning exceeded its configured runtime budget",
              source: __MODULE__,
              details: %{
                code: :workflow_intent_timeout,
                max_runtime_ms: launch.max_runtime_ms
              }
            )
          )

        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> failure
        after
          100 ->
            Process.demonitor(monitor, [:flush])
            failure
        end
    end
  end

  defp run_workflow_intent(launch, intent) do
    store = store!()

    with {:ok, workspace} <- intent_workspace(launch),
         planning <- plan_workflow_intent(store, workspace, launch, intent) do
      handle_workflow_intent_result(planning, store, launch, intent)
    else
      {:error, reason} -> record_workflow_intent_failure(launch, reason)
    end
  rescue
    exception ->
      record_workflow_intent_failure(
        launch,
        Error.from_exception(exception,
          source: __MODULE__,
          message: "Workbench workflow planning failed"
        )
      )
  end

  defp plan_workflow_intent(store, workspace, launch, intent) do
    opts =
      [
        strategy: intent.strategy,
        model: launch.model,
        scope_type: :session,
        scope_id: launch.session_id,
        workflow_key: intent_workflow_key(launch),
        actor: "workbench:planner",
        write_policy: launch.write_policy,
        capability_profile: launch.capability_profile,
        conversation_history: launch.conversation_history,
        receive_timeout: min(launch.max_runtime_ms, 120_000),
        llm_opts: [receive_timeout: min(launch.max_runtime_ms, 120_000)]
      ]
      |> maybe_put(:client, intent_planner_client())

    case Keyword.get(config(), :intent_planner_fun) do
      fun when is_function(fun, 4) -> fun.(store, workspace, intent.request, opts)
      _other -> IntentPlanner.plan(store, workspace, intent.request, opts)
    end
  end

  defp intent_planner_client do
    case Keyword.get(config(), :intent_planner_client) do
      fun when is_function(fun, 3) -> fun
      module when is_atom(module) -> module
      _other -> nil
    end
  end

  defp intent_workspace(launch) do
    path_policy =
      case launch.write_policy do
        :docs_only -> PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
        :workspace_review -> PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: ["."])
        :none -> PathPolicy.new!(hidden_policy: :deny, allowed_write_roots: ["."])
      end

    Workspace.new(root: launch.cwd, path_policy: path_policy, persistence: store!())
  end

  defp handle_workflow_intent_result(
         {:ok, %{strategy: :direct, status: :ready} = result},
         _store,
         launch,
         _intent
       ) do
    with {:ok, _event} <- record_workflow_intent_event(launch, result, :ok) do
      run_agent(launch)
    end
  end

  defp handle_workflow_intent_result(
         {:ok, %{strategy: :reuse_exact, status: :ready} = result},
         store,
         launch,
         intent
       ) do
    workflow_key = result.route.selected.workflow.workflow_key

    with {:ok, _event} <- record_workflow_intent_event(launch, result, :ok),
         {:ok, execution} <-
           WorkflowExecutor.launch_and_run(store, workflow_key, intent.request,
             runner: WorkflowRunner.runner(),
             run: %{
               session_id: launch.session_id,
               trigger: :intent_reuse,
               metadata: %{planning_strategy: :reuse_exact, route: result.route.rationale}
             }
           ) do
      watch_workflow_run(execution.run)
      {:ok, execution}
    else
      {:error, reason} -> record_workflow_intent_failure(launch, reason)
    end
  end

  defp handle_workflow_intent_result(
         {:ok, %{strategy: strategy, status: :drafted} = result},
         store,
         launch,
         _intent
       )
       when strategy in [:draft, :adapt] do
    with {:ok, review} <-
           WorkflowDefinitions.request_review(store, result.definition.workflow.id,
             actor: "workbench:planner",
             session_id: launch.session_id
           ),
         {:ok, _event} <-
           record_workflow_intent_event(
             launch,
             Map.put(result, :definition_review, review),
             :review
           ) do
      {:ok, result}
    else
      {:error, reason} -> record_workflow_intent_failure(launch, reason)
    end
  end

  defp handle_workflow_intent_result(
         {:ok, %{strategy: :adapt, status: :adaptation_required} = result},
         _store,
         launch,
         _intent
       ) do
    record_workflow_intent_event(launch, result, :blocked)
  end

  defp handle_workflow_intent_result({:error, reason}, _store, launch, _intent),
    do: record_workflow_intent_failure(launch, reason)

  defp record_workflow_intent_event(launch, result, status) do
    route = result.route
    definition = Map.get(result, :definition)
    workflow = definition && definition.workflow
    revision = definition && definition.revision

    record_terminal_event(%{
      id: Ids.unique("terminal_event"),
      session_id: launch.session_id,
      run_id: launch.run_id,
      agent: :assistant,
      kind: :status,
      phase: :workflow_intent_routed,
      status: status,
      title: workflow_intent_title(result.strategy, status),
      detail: route.rationale,
      data_json: %{
        planning_strategy: result.strategy,
        rationale: route.rationale,
        reasons: route.reasons,
        considered_candidate_count: length(route.candidates),
        managed_workflow_id: workflow && workflow.id,
        workflow_key: workflow && workflow.workflow_key,
        definition_revision_id: revision && revision.id,
        definition_revision: revision && revision.revision,
        semantic_hash: revision && revision.semantic_hash,
        catalog_hash: revision && revision.catalog_hash
      },
      at: DateTime.utc_now()
    })
  end

  defp record_workflow_intent_failure(launch, reason) do
    error =
      case reason do
        %Error{} = error ->
          error

        _other ->
          Error.from_reason(reason,
            source: __MODULE__,
            message: "Workbench workflow planning failed"
          )
      end

    record_terminal_event(%{
      id: Ids.unique("terminal_event"),
      session_id: launch.session_id,
      run_id: launch.run_id,
      agent: :assistant,
      kind: :error,
      phase: :workflow_intent_failed,
      status: :error,
      title: "Workflow planning failed",
      detail: error.message,
      data_json: %{error: launch_error_payload(error)},
      at: DateTime.utc_now()
    })
  end

  defp workflow_intent_title(:direct, _status), do: "Direct agent selected"
  defp workflow_intent_title(:reuse_exact, _status), do: "Proven workflow selected"
  defp workflow_intent_title(:adapt, :review), do: "Adapted workflow ready for review"
  defp workflow_intent_title(:adapt, :blocked), do: "Workflow adaptation required"
  defp workflow_intent_title(:draft, :review), do: "Drafted workflow ready for review"
  defp workflow_intent_title(strategy, _status), do: "Workflow route: #{strategy}"

  defp intent_workflow_key(launch) do
    suffix = launch.run_id |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]+/u, "-")
    "intent-#{String.trim(suffix, "-")}"
  end

  defp run_agent(launch) do
    try do
      case prepare_agent_run(launch) do
        {:ok, %CliOptions{} = options, %Store{} = store} ->
          runner_opts =
            [
              persistence: store,
              output_fun: fn _line -> :ok end,
              input_fun: fn _prompt -> "d\n" end,
              run_id: launch.run_id,
              conversation_history: Map.get(launch, :conversation_history, [])
            ]
            |> maybe_put(:run_fun, launch.run_fun)
            |> maybe_put(:review_decider, browser_review_decider(launch))

          AgentRunner.run(options, runner_opts)

        {:error, reason} ->
          error =
            Error.from_reason(reason,
              source: __MODULE__,
              message: "Workbench runner failed during startup"
            )

          record_launch_failure(launch, error)
          {:error, error}
      end
    rescue
      exception ->
        error =
          Error.from_exception(exception,
            source: __MODULE__,
            message: "Workbench runner failed during startup"
          )

        record_launch_failure(launch, error)
        {:error, error}
    catch
      kind, reason ->
        error =
          Error.from_reason(reason,
            source: __MODULE__,
            message: "Workbench runner exited during startup",
            details: %{exit_kind: kind}
          )

        record_launch_failure(launch, error)
        {:error, error}
    end
  end

  defp prepare_agent_run(launch) do
    with {:ok, %CliOptions{} = options} <- CliOptions.parse(cli_args(launch)),
         {:ok, %Store{} = store} <- store() do
      {:ok, options, store}
    end
  end

  defp record_launch_failure(launch, %Error{} = error) do
    _ =
      %{
        id: Ids.unique("terminal_event"),
        session_id: launch.session_id,
        run_id: launch.run_id,
        agent: launch.agent,
        kind: :error,
        phase: :launch_failed,
        status: :error,
        title: "Workbench run failed to start",
        detail: error.message,
        data_json:
          %{
            run_id: launch.run_id,
            session_id: launch.session_id,
            cwd: launch.cwd,
            objective: launch.objective,
            model: launch.model,
            client: launch.client,
            approve: launch.approve,
            runtime_approval: launch.approve,
            mode: launch.mode,
            write_policy: launch.write_policy,
            profile: launch.profile,
            toolsets: launch.toolsets,
            disabled_tools: launch.disabled_tools,
            tool_config: launch.tool_config,
            sandbox: launch.sandbox,
            capability_profile: launch.capability_profile,
            trigger: "browser",
            error: launch_error_payload(error)
          }
          |> put_agent_route(launch),
        at: DateTime.utc_now()
      }
      |> record_terminal_event()

    :ok
  end

  defp launch_error_payload(%Error{} = error) do
    %{
      kind: error.kind,
      message: error.message,
      details: inspect(error.details),
      source: inspect(error.source),
      retryable?: error.retryable?,
      metadata: inspect(error.metadata)
    }
  end

  defp maybe_start_objective_operator_resume(session_id, %ReviewRequest{} = review, decision) do
    with %RunicAI.Coding.RLM.ObjectiveSession{} = session <- latest_objective_session(session_id),
         {:ok, resume_kind} <- objective_resume_kind(session, review),
         {:ok, %ReviewDecision{} = review_decision} <-
           objective_operator_decision(review, decision, resume_kind),
         :ok <-
           maybe_ensure_objective_resume_limit(session_id, review, session, resume_kind, decision),
         {:ok, pid} <-
           start_objective_resume_task(session_id, review, session, review_decision, resume_kind) do
      {:ok, pid}
    else
      _other -> :ok
    end
  end

  defp maybe_ensure_objective_resume_limit(
         session_id,
         %ReviewRequest{} = review,
         session,
         resume_kind,
         decision
       ) do
    if session_approval_policy_decision?(decision) do
      ensure_objective_resume_limit(session_id, review, session, resume_kind)
    else
      :ok
    end
  end

  defp session_approval_policy_decision?(decision) do
    (Map.get(decision, :source) || Map.get(decision, "source")) in [
      :session_approval_policy,
      "session_approval_policy"
    ]
  end

  defp ensure_objective_resume_limit(session_id, %ReviewRequest{} = review, session, resume_kind) do
    limit = objective_resume_limit()
    count = objective_resume_count(session_id)

    if count >= limit do
      _ =
        record_objective_resume_limit_event(
          session_id,
          review,
          session,
          resume_kind,
          count,
          limit
        )

      {:error, :objective_resume_limit_reached}
    else
      :ok
    end
  end

  defp objective_resume_limit do
    config()
    |> Keyword.get(:max_objective_auto_resumes, @default_objective_resume_limit)
    |> case do
      limit when is_integer(limit) and limit >= 0 -> limit
      _other -> @default_objective_resume_limit
    end
  end

  defp objective_resume_count(session_id) do
    store = store!()

    SQLite.with_repo(store, fn ->
      query =
        from(event in TerminalEvent,
          where: event.session_id == ^session_id and event.phase == "objective_loop_resume",
          select: count(event.id)
        )

      store.repo.one(query) || 0
    end)
  end

  defp record_objective_resume_limit_event(
         session_id,
         %ReviewRequest{} = review,
         session,
         kind,
         count,
         limit
       ) do
    %{
      id: Ids.unique("terminal_event"),
      session_id: session_id,
      run_id: review.workflow_run_id || field(session, :id),
      agent: :rlm,
      kind: :status,
      phase: :objective_loop_resume,
      status: :blocked,
      title: "Objective auto-resume limit reached",
      detail: "objective still needs #{kind} approval after #{count} automatic resumes",
      data_json: %{
        run_id: review.workflow_run_id || field(session, :id),
        objective_session_id: field(session, :id),
        resume_kind: kind,
        resume_key: review.resume_key || review.id,
        objective_resume_count: count,
        max_objective_auto_resumes: limit
      },
      at: DateTime.utc_now()
    }
    |> record_terminal_event()
  end

  defp objective_resume_kind(
         %RunicAI.Coding.RLM.ObjectiveSession{} = session,
         %ReviewRequest{} = review
       ) do
    cond do
      objective_review_request?(session, review) -> {:ok, :review}
      objective_budget_request?(session, review) -> {:ok, :budget}
      true -> {:error, :not_objective_resume}
    end
  end

  defp objective_review_request?(
         %RunicAI.Coding.RLM.ObjectiveSession{} = session,
         %ReviewRequest{} = review
       ) do
    session.status == :needs_review_approval and
      Enum.any?(session.review_requests, fn request ->
        field(request, :resume_key) in [review.resume_key, review.id]
      end)
  end

  defp objective_budget_request?(
         %RunicAI.Coding.RLM.ObjectiveSession{} = session,
         %ReviewRequest{} = review
       ) do
    session.status == :needs_budget_approval and
      Enum.any?(session.budget_requests, fn request ->
        key = field(request, :resume_key) || field(request, :id)
        key in [review.resume_key, review.id]
      end)
  end

  defp objective_operator_decision(%ReviewRequest{} = review, decision, resume_kind) do
    status =
      case Map.get(decision, :decision_status) || Map.get(decision, "decision_status") do
        status when status in [:approved, "approved"] -> :approved
        status when status in [:edited, "edited"] -> :edited
        status when status in [:denied, "denied", :rejected, "rejected"] -> :rejected
        status when status in [:cancelled, "cancelled"] -> :cancelled
        _other -> nil
      end

    if status do
      ReviewDecision.new(review.resume_key || review.id, status,
        edited_value: Map.get(decision, :edited_value) || Map.get(decision, "edited_value"),
        actor: :workbench,
        metadata:
          %{
            source: :objective_loop_operator_decision,
            decision_source: Map.get(decision, :source) || Map.get(decision, "source"),
            resume_kind: resume_kind,
            additional_iterations:
              Map.get(decision, :additional_iterations) ||
                Map.get(decision, "additional_iterations"),
            additional_runtime_ms:
              Map.get(decision, :additional_runtime_ms) ||
                Map.get(decision, "additional_runtime_ms"),
            approved_runtime_ms:
              Map.get(decision, :approved_runtime_ms) ||
                Map.get(decision, "approved_runtime_ms"),
            max_runtime_ms:
              Map.get(decision, :max_runtime_ms) ||
                Map.get(decision, "max_runtime_ms")
          }
          |> compact_map()
      )
    else
      {:error, :unsupported_objective_review_decision}
    end
  end

  defp start_objective_resume_task(
         session_id,
         %ReviewRequest{} = review,
         %RunicAI.Coding.RLM.ObjectiveSession{} = session,
         %ReviewDecision{} = decision,
         resume_kind
       ) do
    fun = fn ->
      resume_objective_after_operator_decision(session_id, review, session, decision, resume_kind)
    end

    case Process.whereis(@task_supervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(@task_supervisor, fun)
    end
  end

  defp resume_objective_after_operator_decision(
         session_id,
         %ReviewRequest{} = review,
         session,
         decision,
         resume_kind
       ) do
    cfg = config()
    cwd = objective_resume_cwd(session_id)
    approval = current_session_approval_policy(session_id)
    max_runtime_ms = Keyword.get(cfg, :max_runtime_ms, 300_000)

    opts = [
      cwd: cwd,
      session_id: session_id,
      run_id: review.workflow_run_id || session.id,
      run_fun: Keyword.get(cfg, :run_fun),
      approval: approval,
      review_decider:
        browser_review_decider(%{
          approve: approval,
          session_id: session_id,
          max_runtime_ms: max_runtime_ms
        }),
      max_runtime_ms: max_runtime_ms,
      event_sink: fn event ->
        _ = record_terminal_event(event)
        :ok
      end
    ]

    case resume_kind do
      :budget -> RLMRunner.resume_after_budget(session, decision, opts)
      :review -> RLMRunner.resume_after_review(session, decision, opts)
    end
  end

  defp objective_resume_cwd(session_id) do
    case Queries.get_session(store!(), session_id) do
      %AgentSession{workspace_root: cwd} when is_binary(cwd) and cwd != "" -> cwd
      _other -> File.cwd!()
    end
  end

  defp browser_review_decider(%{approve: :always}) do
    fn %RuntimeReviewRequest{} = request, _context ->
      {:ok, Review.allow(request, reason: "review approved by browser always policy")}
    end
  end

  defp browser_review_decider(%{approve: approve} = launch) when approve in [:ask, :safe] do
    fn %RuntimeReviewRequest{} = request, context ->
      if approve == :safe and safe_review?(request) do
        {:ok, Review.allow(request, reason: "review approved by browser safe policy")}
      else
        request = ensure_review_id(request)
        :ok = subscribe_session(launch.session_id)
        _ = ensure_browser_review_request(launch, request, context)

        case session_approval_policy_decision(launch.session_id, request) do
          {:ok, %ReviewDecision{} = decision} ->
            {:ok, decision}

          :pending ->
            wait_for_browser_review_decision(
              launch.session_id,
              request,
              launch.max_runtime_ms,
              System.monotonic_time(:millisecond)
            )
        end
      end
    end
  end

  defp browser_review_decider(_launch), do: nil

  defp safe_review?(%RuntimeReviewRequest{} = request) do
    request.metadata[:safe?] in [true, "true"] or
      request.details[:safe?] in [true, "true"] or
      request.details[:risk] in [:low, "low"]
  end

  defp wait_for_browser_review_decision(
         session_id,
         %RuntimeReviewRequest{} = request,
         timeout_ms,
         started_at
       ) do
    case session_approval_policy_decision(session_id, request) do
      {:ok, %ReviewDecision{} = decision} ->
        {:ok, decision}

      :pending ->
        wait_for_browser_review_decision_from_event(session_id, request, timeout_ms, started_at)
    end
  end

  defp wait_for_browser_review_decision_from_event(session_id, request, timeout_ms, started_at) do
    case persisted_browser_review_decision(session_id, request) do
      {:ok, %ReviewDecision{} = decision} ->
        {:ok, decision}

      :pending ->
        remaining_ms = remaining_timeout(timeout_ms, started_at)

        if remaining_ms <= 0 do
          {:ok, Review.final_stop(request, reason: "browser review timed out")}
        else
          receive do
            {:workbench, :terminal_event, %TerminalEvent{} = event} ->
              case browser_review_decision(event, request) do
                {:ok, %ReviewDecision{} = decision} ->
                  {:ok, decision}

                :ignore ->
                  wait_for_browser_review_decision(session_id, request, timeout_ms, started_at)
              end
          after
            min(@review_wait_poll_interval_ms, remaining_ms) ->
              wait_for_browser_review_decision(session_id, request, timeout_ms, started_at)
          end
        end
    end
  end

  defp session_approval_policy_decision(session_id, %RuntimeReviewRequest{} = request) do
    case current_session_approval_policy(session_id) do
      :always ->
        _ =
          record_review_decision(session_id, request.resume_key, %{
            "action" => "approve",
            "source" => "session_approval_policy"
          })

        {:ok, Review.allow(request, reason: "approved by session approval policy")}

      _other ->
        :pending
    end
  end

  defp persisted_browser_review_decision(session_id, %RuntimeReviewRequest{} = request) do
    case get_review_request(session_id, request.resume_key) do
      {:ok, %ReviewRequest{} = review} ->
        review
        |> persisted_review_decision_payload()
        |> case do
          nil -> :pending
          decision -> decision_from_event(request, decision)
        end

      {:error, :review_not_found} ->
        :pending
    end
  end

  defp persisted_review_decision_payload(%ReviewRequest{decision_json: decision})
       when is_map(decision) and map_size(decision) > 0,
       do: decision

  defp persisted_review_decision_payload(%ReviewRequest{status: status})
       when status in ["approved", "denied", "cancelled"],
       do: %{"decision" => status, "status" => status}

  defp persisted_review_decision_payload(%ReviewRequest{}), do: nil

  defp remaining_timeout(timeout_ms, started_at)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    max(timeout_ms - (System.monotonic_time(:millisecond) - started_at), 0)
  end

  defp remaining_timeout(_timeout_ms, _started_at), do: 0

  defp ensure_review_id(%RuntimeReviewRequest{resume_key: resume_key} = request)
       when is_binary(resume_key) and resume_key != "",
       do: request

  defp ensure_review_id(%RuntimeReviewRequest{} = request) do
    %{request | resume_key: Ids.unique("review")}
  end

  defp ensure_browser_review_request(launch, %RuntimeReviewRequest{} = request, context) do
    if get_review_request(launch.session_id, request.resume_key) == {:error, :review_not_found} do
      request
      |> Event.from_review_request(session_id: launch.session_id, agent: launch.agent)
      |> Map.update!(:data, fn data ->
        Map.merge(data, %{
          run_id: launch.run_id,
          id: request.resume_key,
          status: :review,
          data: %{
            id: request.resume_key,
            kind: request.kind,
            checkpoint: request.checkpoint,
            resume_key: request.resume_key,
            options: request.options,
            details: request.details,
            metadata: request.metadata,
            context: Map.take(context, [:workspace, :params])
          }
        })
      end)
      |> record_terminal_event()
    else
      :ok
    end

    :ok
  end

  defp browser_review_decision(
         %TerminalEvent{kind: "hitl", phase: "review_decision", data_json: data},
         %RuntimeReviewRequest{} = request
       ) do
    decision = field(data, :decision) || %{}

    if field(data, :id) == request.resume_key or field(data, :resume_key) == request.resume_key do
      decision_from_event(request, decision)
    else
      :ignore
    end
  end

  defp browser_review_decision(_event, _request), do: :ignore

  defp decision_from_event(%RuntimeReviewRequest{} = request, decision) do
    metadata = browser_review_decision_metadata(decision)

    case field(decision, :decision) || field(decision, :status) do
      action when action in ["approve", :approve, "approved", :approved] ->
        {:ok, Review.allow(request, reason: "approved in browser", metadata: metadata)}

      action
      when action in ["deny", :deny, "denied", :denied, "reject", :reject, "rejected", :rejected] ->
        {:ok, Review.deny(request, reason: "denied in browser", metadata: metadata)}

      action when action in ["stop", :stop, "cancelled", :cancelled, "cancel", :cancel] ->
        {:ok, Review.final_stop(request, reason: "stopped in browser", metadata: metadata)}

      action when action in ["rewrite", :rewrite, "edited", :edited] ->
        {:ok,
         Review.rewrite(request, field(decision, :edited_value) || "",
           reason: "rewritten in browser",
           metadata: metadata
         )}

      _other ->
        :ignore
    end
  end

  defp browser_review_decision_metadata(decision) do
    [:additional_iterations, :additional_runtime_ms, :approved_runtime_ms, :max_runtime_ms]
    |> Enum.reduce(%{}, fn key, metadata ->
      case field(decision, key) do
        value when value in [nil, ""] -> metadata
        value -> Map.put(metadata, key, value)
      end
    end)
  end

  defp get_review_request(session_id, review_id) do
    store = store!()

    store
    |> Queries.review_requests(session_id)
    |> Enum.find(&(&1.id == review_id))
    |> case do
      nil -> {:error, :review_not_found}
      %ReviewRequest{} = review -> {:ok, review}
    end
  end

  defp pending_review_requests(store, session_id) do
    store
    |> Queries.review_requests(session_id)
    |> Enum.filter(&(&1.status in ["pending", "waiting"]))
  end

  defp normalize_review_decision(params) do
    action = params |> value("action") |> to_string()
    rewrite = params |> value("rewrite") |> to_string() |> String.trim()
    budget_metadata = review_budget_metadata(params)
    source_metadata = review_source_metadata(params)

    case action do
      "approve" ->
        {:ok,
         merge_review_decision_metadata(
           %{
             action: "approve",
             status: :ok,
             decision_status: "approved"
           },
           budget_metadata,
           source_metadata
         )}

      "deny" ->
        {:ok,
         merge_review_decision_metadata(
           %{action: "deny", status: :blocked, decision_status: "denied"},
           source_metadata
         )}

      "stop" ->
        {:ok,
         merge_review_decision_metadata(
           %{action: "stop", status: :blocked, decision_status: "cancelled"},
           source_metadata
         )}

      "rewrite" when rewrite != "" ->
        {:ok,
         merge_review_decision_metadata(
           %{
             action: "rewrite",
             status: :ok,
             decision_status: "edited",
             edited_value: rewrite
           },
           budget_metadata,
           source_metadata
         )}

      "rewrite" ->
        {:error, :empty_rewrite}

      _other ->
        {:error, :invalid_review_decision}
    end
  end

  defp merge_review_decision_metadata(decision, metadata) do
    Map.merge(decision, metadata)
  end

  defp merge_review_decision_metadata(decision, first_metadata, second_metadata) do
    decision
    |> Map.merge(first_metadata)
    |> Map.merge(second_metadata)
  end

  defp review_source_metadata(params) do
    %{
      source: value(params, "source")
    }
    |> compact_map()
  end

  defp review_budget_metadata(params) do
    %{
      additional_iterations: value(params, "additional_iterations"),
      additional_runtime_ms: value(params, "additional_runtime_ms"),
      approved_runtime_ms: value(params, "approved_runtime_ms"),
      max_runtime_ms: value(params, "max_runtime_ms")
    }
    |> compact_map()
  end

  defp review_decision_event(session_id, %ReviewRequest{} = review, decision, agent) do
    decided_at = DateTime.utc_now()

    event_run_id =
      if review.kind in ["workflow_run", "workflow_edit"],
        do: session_id,
        else: review.workflow_run_id || session_id

    %{
      id: Ids.unique("terminal_event"),
      session_id: session_id,
      run_id: event_run_id,
      agent: agent,
      kind: :hitl,
      phase: :review_decision,
      status: decision.status,
      title: "Review #{decision.action}",
      detail: review_decision_detail(review, decision),
      data_json: %{
        id: review.id,
        run_id: review.workflow_run_id || session_id,
        workflow_run_id: review.workflow_run_id,
        kind: review.kind,
        checkpoint: review.checkpoint,
        resume_key: review.resume_key,
        decision:
          %{
            decision: decision.action,
            status: decision.decision_status,
            edited_value: Map.get(decision, :edited_value),
            additional_iterations: Map.get(decision, :additional_iterations),
            additional_runtime_ms: Map.get(decision, :additional_runtime_ms),
            approved_runtime_ms: Map.get(decision, :approved_runtime_ms),
            max_runtime_ms: Map.get(decision, :max_runtime_ms),
            source: Map.get(decision, :source),
            applied_revision_id: Map.get(decision, :applied_revision_id),
            applied_revision: Map.get(decision, :applied_revision),
            applied_semantic_hash: Map.get(decision, :applied_semantic_hash),
            suggestion_disposition: Map.get(decision, :suggestion_disposition),
            decided_at: decided_at
          }
          |> compact_map()
      },
      at: decided_at
    }
  end

  defp review_decision_detail(%ReviewRequest{} = review, decision) do
    case Map.get(decision, :edited_value) do
      nil -> "review #{review.id} #{decision.action}"
      edited -> "review #{review.id} rewrite: #{String.slice(edited, 0, 120)}"
    end
  end

  defp cli_args(launch) do
    [
      "--agent",
      Atom.to_string(launch.agent),
      "--cwd",
      launch.cwd,
      "--mode",
      mode_arg(launch.mode),
      "--profile",
      to_string(launch.profile),
      "--approve",
      Atom.to_string(launch.approve),
      "--write-policy",
      write_policy_arg(launch.write_policy),
      "--session-id",
      launch.session_id,
      "--renderer",
      "text",
      "--color",
      "never",
      "--progress",
      "off",
      "--persistence",
      "none",
      "--max-runtime-ms",
      Integer.to_string(launch.max_runtime_ms)
    ]
    |> append_objective_loop_args(launch)
    |> maybe_append_list("--toolsets", launch.toolsets)
    |> append_repeated("--disable-tool", launch.disabled_tools)
    |> append_tool_config(launch.tool_config)
    |> maybe_append("--model", launch.model)
    |> maybe_append("--client", launch.client)
    |> maybe_append("--output", inferred_output_path(launch.objective))
    |> Kernel.++([launch.objective])
  end

  defp user_message_event(launch) do
    %{
      id: Ids.unique("terminal_event"),
      session_id: launch.session_id,
      run_id: launch.run_id,
      agent: launch.agent,
      kind: :message,
      phase: :user,
      status: :ok,
      title: "User request",
      detail: launch.objective,
      data_json:
        %{
          run_id: launch.run_id,
          role: "user",
          message_kind: "objective",
          content: launch.objective,
          objective: launch.objective,
          conversation_id: "conversation:#{launch.session_id}",
          presentation_group_id: launch.run_id,
          cwd: launch.cwd,
          model: launch.model
        }
        |> put_agent_route(launch),
      at: DateTime.utc_now()
    }
  end

  defp launch_event(launch) do
    %{
      id: Ids.unique("terminal_event"),
      session_id: launch.session_id,
      run_id: launch.run_id,
      agent: launch.agent,
      kind: :status,
      phase: :session,
      status: :running,
      title: "Workbench run queued",
      detail: launch.objective,
      data_json:
        %{
          run_id: launch.run_id,
          session_id: launch.session_id,
          cwd: launch.cwd,
          objective: launch.objective,
          model: launch.model,
          client: launch.client,
          approve: launch.approve,
          mode: launch.mode,
          write_policy: launch.write_policy,
          profile: launch.profile,
          toolsets: launch.toolsets,
          disabled_tools: launch.disabled_tools,
          tool_config: launch.tool_config,
          sandbox: launch.sandbox,
          capability_profile: launch.capability_profile,
          max_runtime_ms: launch.max_runtime_ms,
          max_objective_iterations: launch.max_objective_iterations,
          trigger: "browser"
        }
        |> put_agent_route(launch),
      at: DateTime.utc_now()
    }
  end

  defp capability_profile_event(launch) do
    %{
      id: Ids.unique("terminal_event"),
      session_id: launch.session_id,
      run_id: launch.run_id,
      agent: launch.agent,
      kind: :status,
      phase: :capability_profile_updated,
      status: :ok,
      title: "Capability profile resolved",
      detail: to_string(launch.profile),
      data_json: %{
        run_id: launch.run_id,
        session_id: launch.session_id,
        profile: launch.profile,
        toolsets: launch.toolsets,
        disabled_tools: launch.disabled_tools,
        sandbox: launch.sandbox,
        capability_profile: launch.capability_profile,
        trigger: "browser"
      },
      at: DateTime.utc_now()
    }
  end

  defp put_agent_route(data, %{agent_route: nil}), do: data
  defp put_agent_route(data, %{agent_route: route}) when is_map(route), do: Map.merge(data, route)
  defp put_agent_route(data, _launch), do: data

  defp session_view(%AgentSession{} = session) do
    metadata = session.metadata_json || %{}

    %{
      id: session.id,
      title: first_present(session.objective, session.id),
      objective: session.objective,
      agent: session.agent_kind || "assistant",
      workspace_root: session.workspace_root,
      model: session.model,
      status: session.status || "running",
      started_at: session.started_at,
      completed_at: session.completed_at,
      failed_at: session.failed_at,
      metadata: metadata,
      capability_profile: field(metadata, :capability_profile),
      short_id: short_id(session.id)
    }
  end

  defp session_summary_view(%AgentSession{} = session) do
    %{
      id: session.id,
      title: first_present(session.objective, session.id),
      agent: session.agent_kind || "assistant",
      model: session.model,
      status: session.status || "running",
      started_at: session.started_at,
      completed_at: session.completed_at,
      failed_at: session.failed_at,
      short_id: short_id(session.id)
    }
  end

  defp capability_profile_view(%AgentSession{} = session, runs, events) do
    metadata = session.metadata_json || %{}

    field(metadata, :capability_profile) ||
      Enum.find_value(runs, fn run -> field(run.metadata_json || %{}, :capability_profile) end) ||
      Enum.find_value(events, fn event -> field(event.data_json || %{}, :capability_profile) end)
  end

  defp message_view(%AgentMessage{} = message) do
    %{
      id: message.id,
      role: message.role,
      kind: message.message_kind,
      source_step: message.source_step,
      workflow_node: message.workflow_node,
      content: message.content || "",
      content_json: message.content_json || %{},
      stream_complete: message.stream_complete,
      transient: message.transient,
      created_at: message.created_at
    }
  end

  defp visible_chat_messages(messages) do
    substantive =
      Enum.reject(messages, fn message ->
        message.transient or assistant_summary_message?(message)
      end)

    case substantive do
      [] -> messages
      visible -> dedupe_visible_chat_messages(visible)
    end
  end

  defp dedupe_visible_chat_messages(messages) do
    messages
    |> Enum.reverse()
    |> Enum.uniq_by(fn message ->
      {
        message.presentation_group_id || message.session_id,
        message.role,
        message.message_kind,
        normalized_message_content(message.content)
      }
    end)
    |> Enum.reverse()
  end

  defp normalized_message_content(content) do
    content
    |> to_string()
    |> String.trim()
  end

  defp assistant_summary_message?(%AgentMessage{role: "assistant", message_kind: "summary"}),
    do: true

  defp assistant_summary_message?(%AgentMessage{}), do: false

  defp core_event_from_persisted(%TerminalEvent{} = event) do
    CoreEvent.new!(event.kind,
      id: event.id,
      at: event.at,
      session_id: event.session_id,
      run_id: event.run_id,
      agent: event.agent,
      phase: event.phase,
      status: event.status,
      title: event.title,
      detail: event.detail,
      data: event.data_json || %{}
    )
  end

  defp event_view(%TerminalEvent{} = event) do
    %{
      id: event.id,
      session_id: event.session_id,
      run_id: event.run_id,
      sequence: event.sequence,
      at: event.at,
      agent: event.agent,
      kind: event.kind,
      phase: event.phase,
      status: event.status,
      title: event.title,
      detail: event.detail,
      data: event.data_json || %{}
    }
  end

  defp event_view(_event), do: nil

  defp sandbox_execution_views(events) do
    events
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&sandbox_event?/1)
    |> Enum.map(&sandbox_execution_view/1)
  end

  defp sandbox_event?(event) do
    data = field(event, :data) || %{}
    phase = event |> field(:phase) |> to_string()
    trace_kind = data |> field(:trace_kind) |> to_string()

    phase == "sandbox" or String.starts_with?(trace_kind, "coding_sandbox_")
  end

  defp sandbox_execution_view(event) do
    data = field(event, :data) || %{}
    metadata = field(data, :metadata) || %{}
    input = field(data, :input) || field(metadata, :input) || %{}
    output = field(data, :output) || %{}
    output_metadata = field(output, :metadata) || %{}
    files_changed = field(output, :files_changed) || []
    artifacts = field(output, :artifacts) || []
    proof = sandbox_execution_proof(event, metadata, input, output, output_metadata)

    %{
      id: field(event, :id),
      run_id: field(event, :run_id),
      sequence: field(event, :sequence),
      at: field(event, :at),
      status: field(event, :status),
      phase: field(event, :phase),
      trace_kind: field(data, :trace_kind),
      title: field(event, :title),
      detail: field(event, :detail),
      sandbox: field(metadata, :sandbox) || field(input, :sandbox),
      runtime: field(metadata, :runtime) || field(input, :runtime),
      network: field(metadata, :network) || field(input, :network),
      backend: field(output, :backend) || field(metadata, :backend),
      isolation_level: field(output, :isolation_level) || field(metadata, :isolation_level),
      security_boundary?: sandbox_execution_security_boundary?(metadata, output_metadata),
      session_id: sandbox_execution_session_id(metadata, output_metadata),
      vm_id: field(output_metadata, :vm_id),
      container_name: field(output_metadata, :container_name),
      workspace_mode: sandbox_execution_workspace_mode(metadata, output_metadata),
      workspace_mount: field(output_metadata, :workspace_mount),
      copy_in_status: sandbox_copy_in_status(input, metadata, output_metadata),
      copy_back_status: sandbox_copy_back_status(field(event, :status), files_changed, artifacts),
      exit_status: field(output, :exit_status),
      duration_ms: field(output, :duration_ms),
      output_bytes: field(output, :output_bytes),
      files_changed: files_changed,
      artifacts: artifacts,
      diagnostics: field(output, :diagnostics) || [],
      proof: proof
    }
    |> compact_map()
  end

  defp sandbox_execution_proof(event, metadata, input, output, output_metadata) do
    files_changed = field(output, :files_changed) || []
    artifacts = field(output, :artifacts) || []

    %{
      execution_event_id: field(event, :id),
      run_id: field(event, :run_id),
      backend: field(output, :backend) || field(metadata, :backend),
      sandbox:
        field(metadata, :sandbox) || field(input, :sandbox) || field(output_metadata, :sandbox),
      runtime:
        field(metadata, :runtime) || field(input, :runtime) || field(output_metadata, :runtime),
      network:
        field(metadata, :network) || field(input, :network) || field(output_metadata, :network),
      isolation_level: field(output, :isolation_level) || field(metadata, :isolation_level),
      security_boundary?: sandbox_execution_security_boundary?(metadata, output_metadata),
      session_id: sandbox_execution_session_id(metadata, output_metadata),
      vm_id: field(output_metadata, :vm_id),
      checkpoint_id: field(metadata, :checkpoint_id) || field(output_metadata, :checkpoint_id),
      service_id: field(metadata, :service_id) || field(output_metadata, :service_id),
      proxy_id: field(metadata, :proxy_id) || field(output_metadata, :proxy_id),
      container_name: field(output_metadata, :container_name),
      workspace_root: field(metadata, :workspace_root),
      workspace_mode: sandbox_execution_workspace_mode(metadata, output_metadata),
      workspace_mount: field(output_metadata, :workspace_mount),
      request_file_count: input |> field(:file_paths) |> List.wrap() |> length(),
      files_changed_count: length(files_changed),
      artifact_count: length(artifacts),
      copy_in_status: sandbox_copy_in_status(input, metadata, output_metadata),
      copy_back_status: sandbox_copy_back_status(field(event, :status), files_changed, artifacts),
      state_model: sandbox_capability_field(metadata, :state_model),
      transport_model: sandbox_capability_field(metadata, :transport_model),
      session_model: sandbox_capability_field(metadata, :session)
    }
    |> compact_map()
  end

  defp sandbox_execution_security_boundary?(metadata, output_metadata) do
    field(output_metadata, :security_boundary?) ||
      sandbox_capability_field(metadata, :security_boundary?)
  end

  defp sandbox_execution_session_id(metadata, output_metadata) do
    field(metadata, :session_id) || field(output_metadata, :session_id)
  end

  defp sandbox_execution_workspace_mode(metadata, output_metadata) do
    field(output_metadata, :workspace_mode) ||
      metadata
      |> sandbox_capability_field(:workspace)
      |> field(:mode)
  end

  defp sandbox_capability_field(metadata, key) do
    metadata
    |> field(:capability)
    |> field(key)
  end

  defp sandbox_copy_in_status(input, metadata, output_metadata) do
    cond do
      input |> field(:file_paths) |> List.wrap() |> Enum.any?() ->
        "request_files_uploaded"

      not is_nil(sandbox_execution_workspace_mode(metadata, output_metadata)) ->
        "workspace_mode:#{sandbox_execution_workspace_mode(metadata, output_metadata)}"

      true ->
        nil
    end
  end

  defp sandbox_copy_back_status(status, files_changed, artifacts) do
    cond do
      List.wrap(files_changed) != [] ->
        "files_changed"

      List.wrap(artifacts) != [] ->
        "artifacts_captured"

      status in ["ok", :ok, "pass", :pass] ->
        "no_changes_reported"

      status in ["running", :running] ->
        "pending"

      true ->
        "not_reported"
    end
  end

  defp child_repair_views(events) do
    events
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&child_repair_event?/1)
    |> Enum.reduce(%{}, fn event, acc ->
      key = child_repair_key(event)

      Map.update(acc, key, child_repair_group(event), fn group ->
        child_repair_group_put(group, event)
      end)
    end)
    |> Map.values()
    |> Enum.map(&child_repair_view/1)
    |> Enum.sort_by(&{field(&1, :sort_sequence) || 0, field(&1, :attempt) || 0})
    |> Enum.map(&Map.delete(&1, :sort_sequence))
  end

  defp child_repair_event?(event) do
    phase = event |> field(:phase) |> to_string()

    phase in [
      "child_noop_repair_started",
      "child_noop_repair_completed",
      "child_patch_repair_started",
      "child_patch_repair_completed"
    ]
  end

  defp child_repair_key(event) do
    {
      child_repair_type(event),
      child_repair_event_field(event, :node_id) || "unknown",
      child_repair_event_field(event, :attempt) || 0
    }
  end

  defp child_repair_group(event) do
    %{type: child_repair_type(event)}
    |> child_repair_group_put(event)
  end

  defp child_repair_group_put(group, event) do
    case child_repair_action(event) do
      :started -> Map.put(group, :started, event)
      :completed -> Map.put(group, :completed, event)
      _other -> group
    end
  end

  defp child_repair_type(event) do
    event
    |> field(:phase)
    |> to_string()
    |> case do
      "child_patch_repair_" <> _rest -> :patch
      "child_noop_repair_" <> _rest -> :noop
      _other -> :child
    end
  end

  defp child_repair_action(event) do
    event
    |> field(:phase)
    |> to_string()
    |> case do
      "child_" <> rest when is_binary(rest) ->
        cond do
          String.ends_with?(rest, "_started") -> :started
          String.ends_with?(rest, "_completed") -> :completed
          true -> nil
        end

      _other ->
        nil
    end
  end

  defp child_repair_view(%{type: type} = group) do
    started = Map.get(group, :started)
    completed = Map.get(group, :completed)
    event = completed || started
    status = child_repair_status(started, completed)
    repaired? = child_repair_event_field(completed, :repaired?)
    changed_files = child_repair_event_field(completed, :changed_files) |> List.wrap()
    diagnostics = child_repair_diagnostics(started, completed)

    %{
      id: child_repair_id(type, event),
      type: to_string(type),
      status: status,
      title: child_repair_title(type, status, repaired?),
      detail: child_repair_detail(type, event, diagnostics, changed_files),
      node_id: child_repair_event_field(event, :node_id),
      mode: child_repair_event_field(event, :mode),
      attempt: child_repair_event_field(event, :attempt),
      reason:
        child_repair_event_field(started, :reason) || child_repair_event_field(event, :reason),
      diagnostics: diagnostics,
      changed_files: changed_files,
      changed_file_count: length(changed_files),
      repaired?: repaired?,
      next_action: child_repair_next_action(status, repaired?),
      started_at: field(started || %{}, :at),
      completed_at: field(completed || %{}, :at),
      run_id: field(event || %{}, :run_id),
      sort_sequence: field(completed || started || %{}, :sequence)
    }
    |> compact_map()
  end

  defp child_repair_id(type, event) do
    [
      "child-repair",
      type,
      child_repair_event_field(event, :node_id) || "unknown",
      child_repair_event_field(event, :attempt) || 0
    ]
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
  end

  defp child_repair_status(_started, completed) when is_map(completed) do
    if child_repair_event_field(completed, :repaired?) == true, do: "repaired", else: "unresolved"
  end

  defp child_repair_status(started, _completed) when is_map(started), do: "running"
  defp child_repair_status(_started, _completed), do: "unknown"

  defp child_repair_title(:patch, "repaired", _repaired?), do: "Malformed patch repaired"
  defp child_repair_title(:patch, "running", _repaired?), do: "Repairing malformed patch"
  defp child_repair_title(:patch, _status, _repaired?), do: "Malformed patch still needs repair"
  defp child_repair_title(:noop, "repaired", _repaired?), do: "No-op child repaired"
  defp child_repair_title(:noop, "running", _repaired?), do: "Repairing no-op child"
  defp child_repair_title(:noop, _status, _repaired?), do: "No-op child still needs repair"
  defp child_repair_title(_type, "repaired", _repaired?), do: "Child repair completed"
  defp child_repair_title(_type, "running", _repaired?), do: "Child repair running"
  defp child_repair_title(_type, _status, _repaired?), do: "Child repair unresolved"

  defp child_repair_detail(type, event, diagnostics, changed_files) do
    node = child_repair_event_field(event, :node_id) || "unknown node"
    attempt = child_repair_event_field(event, :attempt) || 1
    reason = child_repair_event_field(event, :reason) |> stringify()
    diagnostic = child_repair_diagnostic_text(diagnostics)

    [
      "#{child_repair_type_label(type)} repair attempt #{attempt} for #{node}.",
      if(reason, do: "Reason: #{reason}."),
      if(changed_files != [], do: "Changed #{Enum.join(changed_files, ", ")}."),
      if(diagnostic, do: "Diagnostic: #{diagnostic}.")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp child_repair_type_label(:patch), do: "Patch"
  defp child_repair_type_label(:noop), do: "No-op"
  defp child_repair_type_label(type), do: type |> stringify() |> first_present("Child")

  defp child_repair_diagnostic_text([]), do: nil

  defp child_repair_diagnostic_text([diagnostic | _rest]) when is_map(diagnostic) do
    message = field(diagnostic, :message)
    code = field(diagnostic, :code)
    details = field(diagnostic, :details)
    op = field(details, :op)

    [message, code && "(#{code})", op && "op=#{op}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> first_present(nil)
  end

  defp child_repair_diagnostic_text([diagnostic | _rest]), do: stringify(diagnostic)

  defp child_repair_next_action("repaired", true),
    do: "Continue downstream verification or final objective proof."

  defp child_repair_next_action("running", _repaired?),
    do: "Wait for the child repair attempt to finish."

  defp child_repair_next_action(_status, _repaired?),
    do: "Escalate to objective-loop repair or request operator review."

  defp child_repair_diagnostics(started, completed) do
    (child_repair_event_field(started, :diagnostics) ||
       child_repair_event_field(completed, :diagnostics) ||
       [])
    |> List.wrap()
    |> Enum.take(5)
  end

  defp child_repair_event_field(nil, _key), do: nil

  defp child_repair_event_field(event, key) do
    progress_event_field(event, key)
  end

  defp plan_workflow_graph_view(events) do
    events
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      case compile_event_graph_summary(event) do
        nil -> nil
        graph -> workflow_graph_view(event, graph)
      end
    end)
  end

  defp compile_event_graph_summary(event) do
    phase = event |> field(:phase) |> to_string()

    if phase in ["compile_completed", "compiled"] do
      data = field(event, :data) || %{}
      compiled = field(data, :compiled) || field(field(data, :data) || %{}, :compiled) || %{}

      field(data, :graph_summary) ||
        field(compiled, :graph_summary) ||
        field(field(compiled, :runic) || %{}, :graph_summary)
    end
  end

  defp workflow_graph_view(event, graph) when is_map(graph) do
    mermaid = graph_mermaid(graph) || GraphPresenter.to_mermaid(graph)

    %{
      title: "Compiled workflow graph",
      mermaid: mermaid,
      fallback: GraphPresenter.adjacency_text(graph),
      metadata: %{
        run_id: field(event, :run_id),
        phase: field(event, :phase),
        sequence: field(event, :sequence)
      },
      nodes: graph_nodes(graph),
      edges: graph_edges(graph),
      acceptance: List.wrap(field(graph, :stop_conditions)),
      source_hash: hash_source(mermaid || inspect(graph))
    }
  end

  defp workflow_graph_view(_event, _graph), do: nil

  defp graph_mermaid(graph) do
    graph
    |> field(:runic)
    |> field(:serializers)
    |> field(:mermaid)
    |> case do
      source when is_binary(source) and source != "" -> source
      _other -> nil
    end
  end

  defp graph_nodes(graph) do
    runic = field(graph, :runic) || %{}

    (field(graph, :nodes) || field(graph, :components) || field(runic, :native_nodes) || [])
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.map(fn {node, index} -> graph_node(node, index) end)
  end

  defp graph_node(node, index) when is_map(node) do
    id = field(node, :name) || field(node, :id) || "node_#{index}"

    %{
      id: to_string(id),
      label: to_string(field(node, :label) || field(node, :title) || field(node, :name) || id),
      kind: stringify(field(node, :kind) || field(node, :type)),
      status: stringify(field(node, :status)),
      execution_shape: stringify(field(node, :execution_shape)),
      inputs: field(node, :inputs) || %{},
      outputs: field(node, :outputs) || %{},
      policy: field(node, :policy) || %{},
      replay:
        node
        |> field(:metadata)
        |> field(:workflow_ir_replay),
      effects:
        node
        |> field(:metadata)
        |> field(:workflow_ir_effects)
        |> List.wrap()
        |> Enum.map(&to_string/1)
    }
  end

  defp graph_node(node, index) do
    id = stringify(node) || "node_#{index}"

    %{
      id: id,
      label: id,
      kind: nil,
      status: nil,
      execution_shape: nil,
      inputs: %{},
      outputs: %{},
      policy: %{},
      replay: nil,
      effects: []
    }
  end

  defp graph_edges(graph) do
    runic = field(graph, :runic) || %{}

    (field(graph, :edges) || field(runic, :edgelist) || [])
    |> List.wrap()
    |> Enum.map(&graph_edge/1)
    |> Enum.reject(&is_nil/1)
  end

  defp graph_edge(edge) when is_map(edge) do
    from = field(edge, :from) || field(edge, :source)
    to = field(edge, :to) || field(edge, :target)

    if is_nil(from) or is_nil(to) do
      nil
    else
      %{from: to_string(from), to: to_string(to), label: stringify(field(edge, :label))}
    end
  end

  defp graph_edge(_edge), do: nil

  defp progress_summary_view(session, events, blocked_evidence) do
    events = Enum.reject(events, &is_nil/1)
    latest = latest_progress_event(events)
    latest_node = latest_progress_field_event(events, [:node_id, :node, :current_node])

    latest_child =
      latest_progress_field_event(events, [:child_id, :child_agent_id, :current_child])

    latest_objective =
      latest_progress_field_event(events, [
        :objective_session_id,
        :objective,
        :current_iteration,
        :iteration_count,
        :objective_iteration_count,
        :objective_session,
        :objective_session_state,
        :objective_decision
      ])

    latest_elapsed = latest_progress_field_event(events, [:elapsed_ms])
    latest_max_runtime = latest_progress_field_event(events, [:max_runtime_ms])
    latest_remaining = latest_progress_field_event(events, [:remaining_ms, :remaining_runtime_ms])
    latest_deadline = latest_progress_field_event(events, [:run_deadline_ms])
    latest_timeout = latest_progress_field_event(events, [:selected_timeout_ms])

    %{
      event_count: length(events),
      latest_event: latest,
      current_node:
        field(blocked_evidence || %{}, :current_node) ||
          progress_event_field(latest_node, :node_id) ||
          progress_event_field(latest_node, :node) ||
          progress_event_field(latest_node, :current_node),
      current_child:
        field(blocked_evidence || %{}, :current_child) ||
          progress_event_field(latest_child, :child_id) ||
          progress_event_field(latest_child, :child_agent_id) ||
          progress_event_field(latest_child, :current_child),
      objective:
        progress_event_field(latest_objective, :objective) ||
          objective_session_field(latest_objective, :objective),
      objective_status:
        objective_session_field(latest_objective, :status) ||
          progress_event_field(latest_objective, :status),
      objective_action:
        objective_decision_field(latest_objective, :action) ||
          progress_event_field(latest_objective, :action),
      objective_iteration:
        progress_event_field(latest_objective, :current_iteration) ||
          progress_event_field(latest_objective, :iteration_count) ||
          progress_event_field(latest_objective, :objective_iteration_count) ||
          objective_session_field(latest_objective, :iteration_count),
      objective_max_iterations:
        progress_event_field(latest_objective, :max_iterations) ||
          objective_session_field(latest_objective, :max_iterations),
      objective_open_task_count: progress_task_count(latest_objective, :open_tasks),
      objective_completed_task_count: progress_task_count(latest_objective, :completed_tasks),
      objective_error_kind: objective_error_field(latest_objective, :kind),
      objective_error_message: objective_error_field(latest_objective, :message),
      objective_error_reason:
        objective_error_field(latest_objective, :reason_message) ||
          objective_error_field(latest_objective, :reason),
      elapsed_ms:
        field(blocked_evidence || %{}, :elapsed_ms) ||
          progress_event_field(latest_elapsed, :elapsed_ms),
      max_runtime_ms:
        field(blocked_evidence || %{}, :max_runtime_ms) ||
          progress_event_field(latest_max_runtime, :max_runtime_ms),
      remaining_ms:
        field(blocked_evidence || %{}, :remaining_ms) ||
          progress_event_field(latest_remaining, :remaining_ms) ||
          progress_event_field(latest_remaining, :remaining_runtime_ms),
      run_deadline_ms: progress_event_field(latest_deadline, :run_deadline_ms),
      selected_timeout_ms: progress_event_field(latest_timeout, :selected_timeout_ms),
      event_trail: "#{length(events)} persisted events"
    }
    |> compact_map()
    |> align_progress_with_session(session)
  end

  defp align_progress_with_session(summary, session) do
    session_status = session |> field(:status) |> stringify()
    objective_status = summary |> field(:objective_status) |> stringify()

    if session_status in [
         "waiting",
         "review",
         "blocked",
         "failed",
         "cancelled",
         "stopped",
         "completed"
       ] and
         objective_status in [nil, "pending", "running"] do
      summary
      |> Map.put(:objective_status, session_status)
      |> drop_stale_continue_action()
    else
      summary
    end
  end

  defp drop_stale_continue_action(summary) do
    if summary |> field(:objective_action) |> stringify() == "continue" do
      Map.delete(summary, :objective_action)
    else
      summary
    end
  end

  defp latest_progress_event(events) do
    events
    |> Enum.reverse()
    |> Enum.find(&progress_event?/1) ||
      List.last(events)
  end

  defp progress_event?(event) do
    kind = event |> field(:kind) |> to_string()
    phase = event |> field(:phase) |> to_string()

    kind in ["rlm_plan", "rlm_node", "repair", "summary", "hitl", "status"] or
      String.contains?(kind, "coding_command") or
      String.contains?(kind, "coding_process") or
      String.contains?(phase, "proposal") or
      String.contains?(phase, "node") or
      String.contains?(phase, "child") or
      String.contains?(phase, "budget") or
      String.contains?(phase, "objective_loop") or
      String.contains?(phase, "repair") or
      String.contains?(phase, "scorecard")
  end

  defp latest_progress_field_event(events, keys) do
    events
    |> Enum.reverse()
    |> Enum.find(fn event ->
      Enum.any?(keys, &(not is_nil(progress_event_field(event, &1))))
    end)
  end

  defp progress_event_field(nil, _key), do: nil

  defp progress_event_field(event, key) do
    data = field(event, :data) || %{}
    nested = field(data, :data) || %{}

    field(nested, key) || field(data, key) || field(event, key)
  end

  defp objective_session_field(nil, _key), do: nil

  defp objective_session_field(event, key) do
    event
    |> progress_event_field(:objective_session)
    |> field(key)
  end

  defp objective_decision_field(nil, _key), do: nil

  defp objective_decision_field(event, key) do
    session_decision =
      event
      |> progress_event_field(:objective_session)
      |> field(:decision)

    top_level_decision = progress_event_field(event, :objective_decision)

    field(session_decision, key) || field(top_level_decision, key)
  end

  defp objective_error_field(nil, _key), do: nil

  defp objective_error_field(event, key) do
    summary_error =
      event
      |> progress_event_field(:objective_session)
      |> field(:latest_error)

    state_error =
      event
      |> progress_event_field(:objective_session_state)
      |> field(:latest_error)

    direct_error = progress_event_field(event, :latest_error)

    field(summary_error, key) ||
      field(state_error, key) ||
      field(direct_error, key) ||
      objective_session_field(event, :"latest_error_#{key}")
  end

  defp progress_task_count(nil, _key), do: nil

  defp progress_task_count(event, key) do
    case progress_event_field(event, key) do
      tasks when is_list(tasks) -> length(tasks)
      _other -> nil
    end
  end

  defp tool_call_view(%ToolCall{} = call) do
    %{
      id: call.id,
      session_id: call.session_id,
      workflow_run_id: call.workflow_run_id,
      tool_name: call.tool_name,
      tool_id: call.tool_id,
      status: call.status,
      args: call.args_json || %{},
      result: call.result_json || %{},
      error: call.error_json || %{},
      requested_at: call.requested_at,
      started_at: call.started_at,
      completed_at: call.completed_at
    }
  end

  defp run_view(store, %WorkflowRun{} = run) do
    definition = workflow_definition_view(store, run)

    %{
      id: run.id,
      workflow_key: run.workflow_key,
      workflow_name: run.workflow_name,
      managed_workflow_id: run.managed_workflow_id,
      definition_revision_id: run.definition_revision_id,
      definition_revision: run.definition_revision,
      definition_hash: run.definition_hash,
      compiled_artifact_id: run.compiled_artifact_id,
      compiled_hash: run.compiled_hash,
      catalog_hash: run.catalog_hash,
      status: run.status,
      trigger: run.trigger,
      parent_run_id: run.parent_run_id,
      parent_node_id: run.parent_node_id,
      invocation_key: run.invocation_key,
      attempt: run.attempt,
      supersedes_run_id: run.supersedes_run_id,
      metadata: run.metadata_json || %{},
      started_at: run.started_at || run.inserted_at,
      completed_at: run.completed_at,
      failed_at: run.failed_at,
      output_summary: workflow_run_output_summary(run.output_blob),
      definition: definition
    }
  end

  defp workflow_run_output_summary(blob) when is_binary(blob) do
    output = Term.from_blob(blob)
    scorecard = field(output, :scorecard) || %{}
    artifacts = output |> field(:artifacts) |> List.wrap()
    metrics = field(output, :execution_metrics) || %{}

    %{
      objective_status: scorecard |> field(:objective_status) |> stringify(),
      artifact_count: length(artifacts),
      artifact_paths:
        artifacts
        |> Enum.map(&field(&1, :path))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(3),
      nodes_executed: field(metrics, :nodes_executed),
      record_map_calls: field(metrics, :record_map_calls),
      dialect: output |> field(:dialect) |> stringify()
    }
    |> compact_map()
  rescue
    ArgumentError -> nil
  end

  defp workflow_run_output_summary(_blob), do: nil

  defp workflow_definition_view(_store, %WorkflowRun{managed_workflow_id: nil}), do: nil

  defp workflow_definition_view(store, %WorkflowRun{} = run) do
    case ManagedWorkflows.get(store, run.managed_workflow_id) do
      nil ->
        nil

      workflow ->
        store
        |> workflow_definition_view(workflow)
        |> Map.merge(%{
          pinned_is_latest?: run.definition_revision_id == workflow.latest_revision_id,
          pinned_is_active?: run.definition_revision_id == workflow.active_revision_id
        })
    end
  end

  defp workflow_definition_view(store, %ManagedWorkflow{} = workflow) do
    latest = WorkflowDefinitions.get_revision(store, workflow.latest_revision_id)
    revisions = WorkflowDefinitions.revisions(store, workflow.id)
    latest_event = workflow |> then(&WorkflowDefinitions.events(store, &1.id)) |> List.last()

    latest_batch =
      workflow
      |> then(&WorkflowDefinitions.operation_batches(store, &1.id))
      |> List.last()

    ir = workflow_ir(latest)
    validation = if ir, do: WorkflowValidator.report(ir, mode: :runnable), else: nil

    %{
      id: workflow.id,
      workflow_key: workflow.workflow_key,
      workflow_name: workflow.workflow_name,
      scope_type: workflow.scope_type,
      scope_id: workflow.scope_id,
      status: workflow.status,
      latest_revision_id: workflow.latest_revision_id,
      latest_revision: latest && latest.revision,
      latest_hash: latest && latest.semantic_hash,
      catalog_hash: latest && latest.catalog_hash,
      current_catalog_hash: WorkflowCatalog.snapshot_hash(),
      catalog_current?: latest && latest.catalog_hash == WorkflowCatalog.snapshot_hash(),
      review_revision_id: workflow.review_revision_id,
      active_revision_id: workflow.active_revision_id,
      latest_action: latest_event && latest_event.action,
      latest_batch: workflow_operation_batch_view(latest_batch, workflow.latest_revision_id),
      revisions: Enum.map(revisions, &workflow_revision_view/1),
      planning: workflow_planning(ir, latest),
      objective: ir && ir.objective,
      policies: (ir && ir.policies) || %{},
      holes: (ir && ir.holes) || [],
      acceptance: (ir && ir.acceptance) || [],
      validation: validation,
      graph: workflow_ir_graph(ir),
      pinned_is_latest?: nil,
      pinned_is_active?: nil
    }
  end

  defp workflow_definitions_for_session(store, session_id) do
    SQLite.with_repo(store, fn ->
      store.repo.all(
        from(workflow in ManagedWorkflow,
          where: workflow.scope_type == "session" and workflow.scope_id == ^session_id,
          order_by: [desc: workflow.updated_at]
        )
      )
    end)
  end

  defp workflow_ir(nil), do: nil

  defp workflow_ir(revision) do
    case WorkflowIR.from_input(revision.ir_json) do
      {:ok, ir} -> ir
      {:error, _reason} -> nil
    end
  end

  defp workflow_planning(nil, _revision), do: %{}

  defp workflow_planning(ir, revision) do
    field(ir.metadata, :planning) || field(revision.metadata_json || %{}, :planning) || %{}
  end

  defp workflow_ir_graph(nil), do: nil

  defp workflow_ir_graph(ir) do
    nodes =
      ir.nodes
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn node ->
        %{
          id: node.id,
          label: node.id,
          kind: node.component,
          status: nil,
          execution_shape: field(node.contract, :execution_shape),
          inputs: field(node.contract, :inputs) || %{},
          outputs: field(node.contract, :outputs) || %{},
          effects: Enum.map(node.effects, &to_string/1),
          replay: field(node.contract, :replay) || %{},
          policy: node.policy,
          arguments: node.arguments
        }
      end)

    edges =
      ir.edges
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn edge ->
        %{
          from: edge.from.node,
          to: edge.to.node,
          label: "#{edge.from.port} -> #{edge.to.port}"
        }
      end)

    graph = %{nodes: nodes, edges: edges, direction: "LR"}
    mermaid = GraphPresenter.to_mermaid(graph, direction: "LR")

    %{
      title: ir.objective,
      nodes: nodes,
      edges: edges,
      mermaid: mermaid,
      fallback: GraphPresenter.adjacency_text(graph),
      acceptance: ir.acceptance,
      source_hash: hash_source(mermaid)
    }
  end

  defp workflow_operation_batch_view(nil, _latest_revision_id), do: nil

  defp workflow_operation_batch_view(batch, latest_revision_id) do
    data = batch.data_json || %{}

    %{
      id: batch.id,
      base_revision_id: batch.base_revision_id,
      result_revision_id: batch.result_revision_id,
      base_hash: batch.base_hash,
      result_hash: batch.result_hash,
      operations: field(data, :operations) || [],
      inverse_operations: field(data, :inverse_operations) || [],
      affected_nodes: field(data, :affected_nodes) || [],
      diff: field(data, :diff) || %{},
      latest?: batch.result_revision_id == latest_revision_id
    }
  end

  defp workflow_revision_view(revision) do
    %{
      id: revision.id,
      revision: revision.revision,
      semantic_hash: revision.semantic_hash,
      parent_revision_id: revision.parent_revision_id,
      created_by: revision.created_by,
      inserted_at: revision.inserted_at
    }
  end

  defp workflow_run(store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.get(WorkflowRun, run_id) end)
  end

  defp workflow_workspace(store, %WorkflowRun{} = run) do
    workflow_workspace(store, run.session_id)
  end

  defp workflow_workspace(store, session_id) when is_binary(session_id) do
    root =
      SQLite.with_repo(store, fn ->
        case store.repo.get(AgentSession, session_id) do
          %AgentSession{workspace_root: root} when is_binary(root) -> root
          _session -> File.cwd!()
        end
      end)

    Workspace.new(root: root)
  end

  defp require_session_definition(
         %ManagedWorkflow{scope_type: "session", scope_id: session_id},
         session_id
       ),
       do: :ok

  defp require_session_definition(%ManagedWorkflow{}, _session_id),
    do: {:error, :workflow_definition_session_mismatch}

  defp decode_workflow_operations(source) do
    with {:ok, decoded} <- Jason.decode(source),
         operations <-
           if(is_map(decoded), do: Map.get(decoded, "operations", decoded), else: decoded),
         true <- is_list(operations) || {:error, :operations_must_be_a_list} do
      {:ok, operations}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_operations_json, error}}
      {:error, _reason} = error -> error
    end
  end

  defp require_expected_revision(revision, opts) do
    expected_id = Keyword.get(opts, :expected_revision_id)
    expected_hash = Keyword.get(opts, :expected_hash)

    cond do
      is_binary(expected_id) and expected_id != revision.id ->
        {:error,
         Error.validation("workflow edit suggestion has a stale base revision",
           source: __MODULE__,
           details: %{
             code: :stale_suggested_revision,
             expected: expected_id,
             actual: revision.id
           }
         )}

      is_binary(expected_hash) and expected_hash != revision.semantic_hash ->
        {:error,
         Error.validation("workflow edit suggestion has a stale base hash",
           source: __MODULE__,
           details: %{
             code: :stale_suggested_hash,
             expected: expected_hash,
             actual: revision.semantic_hash
           }
         )}

      true ->
        :ok
    end
  end

  defp review_request_view(%ReviewRequest{} = request) do
    %{
      id: request.id,
      session_id: request.session_id,
      workflow_run_id: request.workflow_run_id,
      tool_call_id: request.tool_call_id,
      kind: request.kind,
      checkpoint: request.checkpoint,
      resume_key: request.resume_key,
      status: request.status,
      details: request.details_json || %{},
      decision: request.decision_json || %{},
      inserted_at: request.inserted_at
    }
  end

  defp artifact_view(%RunArtifact{} = artifact) do
    metadata = artifact.metadata_json || %{}
    payload = metadata["payload"] || metadata[:payload] || %{}

    %{
      id: artifact.id,
      run_id: artifact.run_id,
      session_id: artifact.session_id,
      path: artifact.path,
      kind: artifact.artifact_kind,
      action: artifact.action,
      sha256: artifact.sha256,
      byte_size: artifact.byte_size,
      title:
        metadata["title"] || metadata[:title] || payload["title"] || payload[:title] ||
          artifact.path || artifact.id,
      preview:
        metadata["preview"] || metadata[:preview] || payload["preview"] || payload[:preview],
      metadata: metadata,
      inserted_at: artifact.inserted_at
    }
  end

  defp scorecard_view(%Scorecard{} = scorecard) do
    data = scorecard.scorecard_json || %{}

    %{
      id: scorecard.id,
      run_id: scorecard.run_id,
      component_id: scorecard.component_id,
      objective_status: scorecard.objective_status,
      summary: data["summary"] || data[:summary],
      acceptance_results: data["acceptance_results"] || data[:acceptance_results] || [],
      residual_risks: data["residual_risks"] || data[:residual_risks] || [],
      changed_files: data["changed_files"] || data[:changed_files] || [],
      data: data,
      created_at: scorecard.created_at
    }
  end

  defp objective_contract_view(events, messages, scorecards) do
    latest_from_events =
      events
      |> Enum.reverse()
      |> Enum.find_value(fn event ->
        data = event.data_json || %{}

        field(data, :objective_contract) ||
          data |> field(:data) |> field(:objective_contract) ||
          data |> field(:blocked_evidence) |> field(:objective_contract) ||
          data |> field(:scorecard) |> field(:metadata) |> field(:objective_contract) ||
          data
          |> field(:data)
          |> field(:scorecard)
          |> field(:metadata)
          |> field(:objective_contract)
      end)

    latest_from_messages =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn message ->
        data = message.content_json || %{}

        field(data, :objective_contract) ||
          data |> field(:blocked_evidence) |> field(:objective_contract)
      end)

    latest_from_scorecards =
      scorecards
      |> Enum.reverse()
      |> Enum.find_value(fn scorecard ->
        scorecard
        |> field(:data)
        |> field(:metadata)
        |> field(:objective_contract)
      end)

    latest_from_events || latest_from_messages || latest_from_scorecards
  end

  defp blocked_evidence_view(%AgentSession{} = session, events, messages, scorecards) do
    explicit =
      events
      |> Enum.reverse()
      |> Enum.find_value(fn event -> event.data_json |> field(:blocked_evidence) end) ||
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn message -> message.content_json |> field(:blocked_evidence) end)

    explicit || derived_blocked_evidence(session, events, scorecards)
  end

  defp derived_blocked_evidence(%AgentSession{status: status}, _events, _scorecards)
       when status not in ["blocked", "failed"],
       do: nil

  defp derived_blocked_evidence(%AgentSession{} = session, events, scorecards) do
    latest_scorecard = List.last(scorecards)
    latest_event = List.last(events)

    %{
      status: session.status,
      objective_status: field(latest_scorecard || %{}, :objective_status),
      residual_risks: field(latest_scorecard || %{}, :residual_risks) || [],
      unsatisfied_acceptance:
        latest_scorecard
        |> field(:acceptance_results)
        |> List.wrap()
        |> Enum.filter(&(field(&1, :status) in ["fail", :fail, "blocked", :blocked])),
      latest_event: event_view(latest_event),
      next_actions: [
        "Inspect the latest blocked event and unsatisfied acceptance checks.",
        "Continue with a targeted repair or rerun with a larger budget when the evidence is budget-related."
      ]
    }
    |> compact_map()
  end

  defp completion_proof_view(
         %AgentSession{} = session,
         messages,
         events,
         sandbox_executions,
         child_repairs,
         reviews,
         artifacts,
         scorecards,
         objective_contract
       ) do
    completion_scorecards = scorecards ++ Enum.flat_map(events, &completion_event_scorecards/1)

    final_message =
      messages
      |> Enum.reverse()
      |> Enum.find(fn message -> field(message, :role) in ["assistant", :assistant] end)

    final_event =
      events
      |> Enum.reverse()
      |> Enum.find(fn event ->
        field(event, :kind) in ["summary", :summary] and field(event, :phase) in ["final", :final]
      end)

    changed_files =
      []
      |> Kernel.++(Enum.flat_map(completion_scorecards, &List.wrap(field(&1, :changed_files))))
      |> Kernel.++(
        Enum.flat_map(sandbox_executions, &completion_paths(field(&1, :files_changed)))
      )
      |> Kernel.++(Enum.flat_map(child_repairs, &List.wrap(field(&1, :changed_files))))
      |> Kernel.++(Enum.flat_map(events, &completion_paths(field(&1, :data))))
      |> Kernel.++(Enum.flat_map(messages, &completion_paths(field(&1, :content_json))))
      |> normalize_completion_paths()

    {delivered_changed_files, scratch_changed_files} =
      split_completion_changed_files(changed_files, objective_contract, completion_scorecards)

    artifact_paths =
      artifacts
      |> Enum.map(&field(&1, :path))
      |> Kernel.++(Enum.flat_map(completion_scorecards, &completion_paths(field(&1, :data))))
      |> Kernel.++(Enum.flat_map(events, &completion_artifact_paths(field(&1, :data))))
      |> Kernel.++(Enum.flat_map(messages, &completion_artifact_paths(field(&1, :content_json))))
      |> normalize_completion_paths()

    review_statuses =
      reviews
      |> Enum.map(&field(&1, :status))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

    scorecard_statuses =
      completion_scorecards
      |> Enum.map(&field(&1, :objective_status))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

    final_output? =
      present_string?(field(final_message || %{}, :content)) or
        present_string?(completion_event_output(final_event))

    scorecard_satisfied? = "objective_satisfied" in scorecard_statuses
    denied_review? = Enum.any?(review_statuses, &(&1 in ["denied", "rejected"]))
    approved_review? = "approved" in review_statuses
    sandbox_proof? = sandbox_executions != []

    proof_categories =
      []
      |> maybe_cons(final_output?, "final_output")
      |> maybe_cons(scorecard_satisfied?, "scorecard")
      |> maybe_cons(objective_contract != nil, "objective_contract")
      |> maybe_cons(delivered_changed_files != [], "changed_files")
      |> maybe_cons(artifact_paths != [], "artifacts")
      |> maybe_cons(sandbox_proof?, "sandbox")
      |> maybe_cons(denied_review? or approved_review?, "review_decision")
      |> Enum.reverse()

    terminal? =
      session.status in [
        "completed",
        "objective_satisfied",
        "blocked",
        "failed",
        "cancelled",
        "stopped"
      ]

    completed? = session.status in ["completed", "objective_satisfied"]
    blocked? = session.status in ["blocked", "failed"]

    has_completion_signal? =
      scorecard_satisfied? or delivered_changed_files != [] or artifact_paths != [] or
        sandbox_proof? or denied_review? or approved_review?

    missing =
      []
      |> maybe_cons(completed? and not final_output?, "final_output")
      |> maybe_cons(completed? and not has_completion_signal?, "completion_evidence")
      |> Enum.reverse()

    %{
      status: session.status,
      terminal?: terminal?,
      completed?: completed?,
      blocked?: blocked?,
      ready?: completed? and missing == [] and has_completion_signal?,
      missing: missing,
      proof_categories: proof_categories,
      final_output?: final_output?,
      scorecard_satisfied?: scorecard_satisfied?,
      objective_contract?: objective_contract != nil,
      changed_files: delivered_changed_files,
      changed_file_count: length(delivered_changed_files),
      delivered_changed_files: delivered_changed_files,
      delivered_changed_file_count: length(delivered_changed_files),
      scratch_changed_files: scratch_changed_files,
      scratch_changed_file_count: length(scratch_changed_files),
      all_changed_files: changed_files,
      all_changed_file_count: length(changed_files),
      artifact_paths: artifact_paths,
      artifact_count: length(artifact_paths),
      sandbox_execution_count: length(sandbox_executions),
      review_statuses: review_statuses,
      denied_review?: denied_review?,
      approved_review?: approved_review?,
      scorecard_statuses: scorecard_statuses
    }
  end

  defp completion_event_scorecards(event) do
    [
      progress_event_field(event, :scorecard),
      progress_event_field(event, :objective_scorecard)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp completion_event_output(nil), do: nil

  defp completion_event_output(event) do
    progress_event_field(event, :output_text) ||
      progress_event_field(event, :reply_text) ||
      progress_event_field(event, :final_output) ||
      progress_event_field(event, :output)
  end

  defp completion_paths(value), do: completion_values(value, [:changed_files, :changed_paths])

  defp completion_artifact_paths(value),
    do: completion_values(value, [:artifact_paths, :artifacts])

  defp completion_values(value, keys) when is_map(value) do
    direct =
      keys
      |> Enum.flat_map(fn key ->
        value
        |> field(key)
        |> List.wrap()
      end)

    nested =
      value
      |> Map.values()
      |> Enum.flat_map(&completion_values(&1, keys))

    direct ++ nested
  end

  defp completion_values(values, keys) when is_list(values),
    do: Enum.flat_map(values, &completion_values(&1, keys))

  defp completion_values(_value, _keys), do: []

  defp normalize_completion_paths(paths) do
    paths
    |> Enum.flat_map(fn
      %{path: path} -> [path]
      %{"path" => path} -> [path]
      value when is_binary(value) -> [value]
      _other -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&invalid_completion_path?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp invalid_completion_path?(""), do: true
  defp invalid_completion_path?("[depth limit]"), do: true
  defp invalid_completion_path?("[cycle]"), do: true
  defp invalid_completion_path?(_path), do: false

  defp split_completion_changed_files(paths, objective_contract, scorecards) do
    allowed_roots = completion_allowed_delivery_roots(objective_contract, scorecards)

    paths
    |> Enum.split_with(fn path ->
      not scratch_completion_path?(path) or
        Enum.any?(allowed_roots, &completion_path_under_root?(path, &1))
    end)
  end

  defp scratch_completion_path?(path) when is_binary(path) do
    String.starts_with?(path, ["tmp/", ".tmp/", ".runic_ai/"])
  end

  defp scratch_completion_path?(_path), do: false

  defp completion_allowed_delivery_roots(objective_contract, scorecards) do
    scorecard_roots =
      scorecards
      |> Enum.flat_map(fn scorecard ->
        scorecard
        |> field(:acceptance_results)
        |> List.wrap()
        |> Enum.flat_map(fn result ->
          result |> field(:metadata) |> field(:allowed_delivery_roots) |> List.wrap()
        end)
      end)

    objective_roots =
      objective_contract
      |> field(:objective)
      |> completion_objective_delivery_roots()

    (scorecard_roots ++ objective_roots)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_completion_delivery_root/1)
    |> Enum.reject(&(&1 in [nil, "", "."]))
    |> Enum.uniq()
  end

  defp completion_objective_delivery_roots(objective) when is_binary(objective) do
    ~r/(?:\.\/)?(?:tmp|apps|packages|examples|fixtures)\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*/
    |> Regex.scan(objective)
    |> List.flatten()
  end

  defp completion_objective_delivery_roots(_objective), do: []

  defp normalize_completion_delivery_root(root) when is_binary(root) do
    root =
      root
      |> String.trim()
      |> String.trim_leading("./")
      |> String.trim_trailing("/")

    case Path.split(root) do
      [prefix, name | _rest] when prefix in ["tmp", "apps", "packages", "examples", "fixtures"] ->
        Path.join(prefix, name)

      _other ->
        root
    end
  end

  defp completion_path_under_root?(path, root) when is_binary(path) and is_binary(root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp completion_path_under_root?(_path, _root), do: false

  defp maybe_cons(list, true, item), do: [item | list]
  defp maybe_cons(list, false, _item), do: list

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp conversation_history(%{session_id: session_id, agent_route: agent_route}) do
    store = store!()

    store
    |> Queries.messages_for_session(session_id)
    |> visible_chat_messages()
    |> filter_routed_conversation_history(agent_route)
    |> Enum.map(fn message ->
      %{
        role: message.role,
        message_kind: message.message_kind,
        content: message.content || ""
      }
    end)
  rescue
    _exception -> []
  end

  defp filter_routed_conversation_history(messages, %{
         route_reason: :non_workspace_rlm_objective
       }) do
    Enum.reject(messages, fn message ->
      message.role == "assistant" and
        String.starts_with?(message.presentation_group_id || "", "rlm:web")
    end)
  end

  defp filter_routed_conversation_history(messages, _agent_route), do: messages

  defp inferred_output_path(objective) when is_binary(objective) do
    objective
    |> output_path_candidates()
    |> List.first()
  end

  defp inferred_output_path(_objective), do: nil

  defp output_path_candidates(objective) do
    Regex.scan(
      ~r/\b(?:write|save|create|persist|output|report)\b.{0,120}?\b(?:to|at|as|in)\s+(`[^`]+`|"[^"]+"|'[^']+'|[A-Za-z0-9_.\/-]+\.(?:md|txt|json|jsonl|csv|exs?|livemd))/i,
      objective,
      capture: :all_but_first
    )
    |> Enum.map(fn [path] -> normalize_referenced_path(path) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_referenced_path(path) do
    path
    |> String.trim(~s(`'" ))
    |> String.replace(~r/[,.!?;:)\]}]+$/, "")
  end

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {key, right_value}, acc ->
      key = equivalent_existing_key(acc, key)
      Map.update(acc, key, right_value, &deep_merge(&1, right_value))
    end)
  end

  defp deep_merge(_left, right), do: right

  defp equivalent_existing_key(map, key) when is_map(map) and is_binary(key) do
    Enum.find(Map.keys(map), key, fn
      existing when is_atom(existing) -> Atom.to_string(existing) == key
      existing -> existing == key
    end)
  end

  defp equivalent_existing_key(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)
    Enum.find(Map.keys(map), key, &(&1 == string_key or &1 == key))
  end

  defp equivalent_existing_key(_map, key), do: key

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp hash_source(source) do
    :crypto.hash(:sha256, source)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank_value?(value) end)
    |> Map.new()
  end

  defp blank_value?(nil), do: true
  defp blank_value?(""), do: true
  defp blank_value?([]), do: true
  defp blank_value?(map) when is_map(map), do: map_size(map) == 0
  defp blank_value?(_value), do: false

  defp require_objective(""), do: {:error, :empty_objective}
  defp require_objective(_objective), do: :ok

  defp choice(nil, _choices, default), do: {:ok, default}

  defp choice(value, choices, default) when is_atom(value) do
    if value in Map.values(choices), do: {:ok, value}, else: {:ok, default}
  end

  defp choice(value, choices, default) do
    normalized =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    {:ok, Map.get(choices, normalized, default)}
  end

  defp normalize_cwd(cwd) when is_binary(cwd) do
    path = Path.expand(cwd)

    if File.dir?(path) do
      {:ok, path}
    else
      {:error, {:invalid_cwd, cwd}}
    end
  end

  defp normalize_cwd(cwd), do: {:error, {:invalid_cwd, cwd}}

  defp normalize_max_runtime(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_max_runtime(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {runtime_ms, ""} when runtime_ms > 0 -> {:ok, runtime_ms}
      _other -> {:error, {:invalid_max_runtime_ms, value}}
    end
  end

  defp normalize_max_runtime(value), do: {:error, {:invalid_max_runtime_ms, value}}

  defp normalize_max_objective_iterations(value) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_max_objective_iterations(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {iterations, ""} when iterations > 0 -> {:ok, iterations}
      _other -> {:error, {:invalid_max_objective_iterations, value}}
    end
  end

  defp normalize_max_objective_iterations(value),
    do: {:error, {:invalid_max_objective_iterations, value}}

  defp normalize_model_selection(params, cfg) do
    direct_model = blank_to_nil(value(params, "model"))
    provider = blank_to_nil(value(params, "model_provider"))
    model_id = blank_to_nil(value(params, "model_id"))
    configured_default = blank_to_nil(Keyword.get(cfg, :default_model))

    cond do
      is_binary(provider) and is_binary(model_id) ->
        "#{provider}:#{model_id}"

      is_binary(direct_model) ->
        direct_model

      is_binary(configured_default) ->
        configured_default

      true ->
        ModelCatalog.default_model_spec()
    end
  end

  defp normalize_profile(nil), do: {:ok, "local-workbench"}

  defp normalize_profile(profile) when is_atom(profile),
    do: {:ok, profile |> Atom.to_string() |> String.replace("_", "-")}

  defp normalize_profile(profile) when is_binary(profile) do
    profile =
      profile
      |> String.trim()
      |> String.replace("_", "-")

    if profile == "", do: {:ok, "local-workbench"}, else: {:ok, profile}
  end

  defp normalize_profile(profile), do: {:ok, to_string(profile)}

  defp normalize_list(nil), do: {:ok, []}
  defp normalize_list(""), do: {:ok, []}

  defp normalize_list(value) when is_binary(value) do
    {:ok,
     value
     |> String.split([",", "\n"], trim: true)
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))
     |> Enum.uniq()}
  end

  defp normalize_list(values) when is_list(values) do
    {:ok,
     values
     |> Enum.flat_map(fn
       value when is_binary(value) -> String.split(value, [",", "\n"], trim: true)
       value -> [to_string(value)]
     end)
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))
     |> Enum.uniq()}
  end

  defp normalize_list(value), do: normalize_list(to_string(value))

  defp normalize_tool_config(nil), do: {:ok, %{}}
  defp normalize_tool_config(""), do: {:ok, %{}}

  defp normalize_tool_config(config) when is_map(config), do: {:ok, config}

  defp normalize_tool_config(config) when is_binary(config) do
    config
    |> String.split([",", "\n"], trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
      case String.split(entry, "=", parts: 2) do
        [key, value] ->
          path = key |> String.trim() |> String.split(".", trim: true)

          if path == [] do
            {:halt, {:error, {:invalid_tool_config, entry}}}
          else
            {:cont, {:ok, put_nested_config(acc, path, parse_config_value(String.trim(value)))}}
          end

        _other ->
          {:halt, {:error, {:invalid_tool_config, entry}}}
      end
    end)
  end

  defp normalize_sandbox_tool_config(config, params) when is_map(config) and is_map(params) do
    sandbox_values = [
      value(params, "sandbox_profile"),
      value(params, "sandbox_backend"),
      value(params, "sandbox_runtime"),
      value(params, "sandbox_runtimes"),
      value(params, "sandbox_network"),
      value(params, "sandbox_stateful"),
      value(params, "sandbox_pool_warm"),
      value(params, "sandbox_pool_max")
    ]

    if Enum.all?(sandbox_values, &blank?/1) do
      {:ok, config}
    else
      with {:ok, sandbox} <- normalize_sandbox_profile(value(params, "sandbox_profile")),
           {:ok, backend} <- normalize_sandbox_backend(value(params, "sandbox_backend")),
           {:ok, runtime} <- normalize_sandbox_runtime(value(params, "sandbox_runtime")),
           {:ok, runtimes} <-
             normalize_sandbox_runtimes(value(params, "sandbox_runtimes"), runtime),
           {:ok, network} <- normalize_sandbox_network(value(params, "sandbox_network")),
           {:ok, stateful?} <- normalize_sandbox_stateful(value(params, "sandbox_stateful")),
           {:ok, pool} <- normalize_sandbox_pool(params) do
        {:ok,
         config
         |> maybe_put_sandbox_config(["code_execution", "enabled"], true)
         |> maybe_put_sandbox_config(["code_execution", "sandbox"], sandbox)
         |> maybe_put_sandbox_config(["code_execution", "backend"], backend)
         |> maybe_put_sandbox_config(["code_execution", "default_backend"], backend)
         |> maybe_put_sandbox_config(["code_execution", "runtime"], runtime)
         |> maybe_put_sandbox_config(["code_execution", "allowed_runtimes"], runtimes)
         |> maybe_put_sandbox_config(["code_execution", "network"], network)
         |> maybe_put_sandbox_config(["code_execution", "stateful?"], stateful?)
         |> maybe_put_sandbox_config(["code_execution", "pool"], pool)
         |> maybe_put_sandbox_config(["code_execution", "workspace", "mode"], "copy_in")
         |> maybe_put_sandbox_config(["code_execution", "workspace", "persist?"], stateful?)}
      end
    end
  end

  defp normalize_sandbox_tool_config(config, _params), do: {:ok, config}

  defp maybe_put_sandbox_config(config, _path, nil), do: config
  defp maybe_put_sandbox_config(config, path, value), do: put_nested_config(config, path, value)

  defp normalize_sandbox_profile(value) do
    value =
      value
      |> blank_to_nil()
      |> case do
        nil ->
          "local_code"

        value ->
          value
          |> to_string()
          |> String.trim()
          |> String.downcase()
          |> String.replace("-", "_")
      end

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, value) do
      {:ok, value}
    else
      {:error, {:invalid_sandbox_profile, value}}
    end
  end

  defp normalize_sandbox_backend(value) do
    value =
      value
      |> blank_to_nil()
      |> case do
        nil ->
          "just_bash"

        value ->
          value |> to_string() |> String.trim() |> String.downcase() |> String.replace("-", "_")
      end

    if value in ~w(just_bash docker podman gvisor vmsan firecracker sprites remote) do
      {:ok, value}
    else
      {:error, {:invalid_sandbox_backend, value}}
    end
  end

  defp normalize_sandbox_runtime(value) do
    value =
      value
      |> blank_to_nil()
      |> case do
        nil -> "bash"
        value -> value |> to_string() |> String.trim() |> String.downcase()
      end

    if value in ~w(bash sh python node elixir lua) do
      {:ok, value}
    else
      {:error, {:invalid_sandbox_runtime, value}}
    end
  end

  defp normalize_sandbox_runtimes(value, fallback_runtime) do
    values =
      case value do
        value when is_list(value) ->
          value

        value when value in [nil, ""] ->
          [fallback_runtime]

        value when is_binary(value) ->
          value
          |> String.split([",", "\n"], trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        value ->
          [value]
      end

    values
    |> Enum.reduce_while({:ok, []}, fn runtime, {:ok, acc} ->
      case normalize_sandbox_runtime(runtime) do
        {:ok, runtime} -> {:cont, {:ok, [runtime | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, []} ->
        {:ok, [fallback_runtime]}

      {:ok, runtimes} ->
        {:ok, finalize_sandbox_runtimes(Enum.reverse(runtimes), fallback_runtime)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp finalize_sandbox_runtimes(["bash"], fallback_runtime) when fallback_runtime != "bash",
    do: [fallback_runtime]

  defp finalize_sandbox_runtimes(runtimes, _fallback_runtime) do
    runtimes
    |> Enum.uniq()
  end

  defp normalize_sandbox_network(value) do
    value =
      value
      |> blank_to_nil()
      |> case do
        nil -> "disabled"
        value -> value |> to_string() |> String.trim() |> String.downcase()
      end

    if value in ~w(disabled restricted host) do
      {:ok, value}
    else
      {:error, {:invalid_sandbox_network, value}}
    end
  end

  defp normalize_sandbox_stateful(value) when value in [true, false], do: {:ok, value}
  defp normalize_sandbox_stateful(value) when value in [nil, ""], do: {:ok, false}
  defp normalize_sandbox_stateful(value) when value in ["true", "1", "yes", "on"], do: {:ok, true}

  defp normalize_sandbox_stateful(value) when value in ["false", "0", "no", "off"],
    do: {:ok, false}

  defp normalize_sandbox_stateful(value), do: {:error, {:invalid_sandbox_stateful, value}}

  defp normalize_sandbox_pool(params) do
    with {:ok, warm} <- normalize_non_negative_integer(value(params, "sandbox_pool_warm"), 0),
         {:ok, max} <- normalize_positive_integer(value(params, "sandbox_pool_max"), 1) do
      if warm <= max do
        {:ok, %{"warm" => warm, "max" => max}}
      else
        {:error, {:invalid_sandbox_pool, %{warm: warm, max: max}}}
      end
    end
  end

  defp normalize_non_negative_integer(value, default) when value in [nil, ""],
    do: {:ok, default}

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp normalize_non_negative_integer(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, {:invalid_non_negative_integer, value}}
    end
  end

  defp normalize_non_negative_integer(value, _default),
    do: {:error, {:invalid_non_negative_integer, value}}

  defp normalize_positive_integer(value, default) when value in [nil, ""], do: {:ok, default}

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_positive_integer(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_positive_integer, value}}
    end
  end

  defp normalize_positive_integer(value, _default),
    do: {:error, {:invalid_positive_integer, value}}

  defp blank?(value), do: is_nil(blank_to_nil(value))

  defp sandbox_launch_summary(tool_config, capability_profile) do
    profile_config =
      capability_profile
      |> field(:config)
      |> field(:code_execution)

    configured = field(tool_config, "code_execution") || %{}
    code_execution = deep_merge(profile_config || %{}, configured)

    %{
      sandbox: field(code_execution, :sandbox) || :local_code,
      backend:
        field(code_execution, :default_backend) || field(code_execution, :backend) || :just_bash,
      runtime: field(code_execution, :runtime) || :bash,
      runtimes:
        field(code_execution, :allowed_runtimes) || field(code_execution, :runtimes) || [:bash],
      network: field(code_execution, :network) || :disabled,
      stateful?: field(code_execution, :stateful?) || false,
      pool: field(code_execution, :pool) || %{},
      workspace: field(code_execution, :workspace) || %{},
      review: field(code_execution, :review) || :unsafe_actions
    }
  end

  defp parse_config_value("true"), do: true
  defp parse_config_value("false"), do: false

  defp parse_config_value(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp put_nested_config(config, [key], value), do: Map.put(config, key, value)

  defp put_nested_config(config, [key | rest], value) do
    Map.update(config, key, put_nested_config(%{}, rest, value), fn nested ->
      put_nested_config(Map.new(nested || %{}), rest, value)
    end)
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, Map.get(@param_atoms, key))
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp first_present(nil, fallback), do: fallback
  defp first_present("", fallback), do: fallback
  defp first_present(value, _fallback), do: value

  defp short_id(id) when is_binary(id) do
    id
    |> String.split(":")
    |> List.last()
    |> String.slice(0, 8)
  end

  defp short_id(_id), do: nil

  defp mode_arg(:read_only), do: "read-only"
  defp mode_arg(mode), do: Atom.to_string(mode)

  defp write_policy_arg(:docs_only), do: "docs-only"
  defp write_policy_arg(:workspace_review), do: "workspace-review"
  defp write_policy_arg(:none), do: "none"
  defp write_policy_arg(policy), do: to_string(policy)

  defp default_write_policy(:patch), do: :workspace_review
  defp default_write_policy(_mode), do: :docs_only

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, _flag, ""), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, to_string(value)]

  defp append_objective_loop_args(args, %{agent: :rlm, max_objective_iterations: iterations}) do
    args ++ ["--objective-loop", "--max-objective-iterations", Integer.to_string(iterations)]
  end

  defp append_objective_loop_args(args, _launch), do: args

  defp maybe_append_list(args, _flag, []), do: args
  defp maybe_append_list(args, _flag, nil), do: args

  defp maybe_append_list(args, flag, values),
    do: args ++ [flag, Enum.join(List.wrap(values), ",")]

  defp append_repeated(args, _flag, []), do: args
  defp append_repeated(args, _flag, nil), do: args

  defp append_repeated(args, flag, values) do
    Enum.reduce(List.wrap(values), args, fn value, acc -> acc ++ [flag, to_string(value)] end)
  end

  defp append_tool_config(args, config) when config in [nil, %{}], do: args

  defp append_tool_config(args, config) when is_map(config) do
    config
    |> flatten_tool_config()
    |> Enum.reduce(args, fn {key, value}, acc ->
      acc ++ ["--tool-config", "#{key}=#{tool_config_cli_value(value)}"]
    end)
  end

  defp tool_config_cli_value(values) when is_list(values),
    do: values |> Enum.map(&to_string/1) |> Enum.join(",")

  defp tool_config_cli_value(value), do: to_string(value)

  defp flatten_tool_config(config, prefix \\ nil) do
    Enum.flat_map(config, fn {key, value} ->
      key = if prefix, do: "#{prefix}.#{key}", else: to_string(key)

      if is_map(value) do
        flatten_tool_config(value, key)
      else
        [{key, value}]
      end
    end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp session_topic(session_id), do: "#{@topic}:session:#{session_id}"
end
