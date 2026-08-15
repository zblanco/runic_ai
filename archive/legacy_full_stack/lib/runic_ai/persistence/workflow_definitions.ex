defmodule RunicAI.Persistence.WorkflowDefinitions do
  @moduledoc """
  Durable lifecycle for canonical workflow IR definitions.

  Stable managed-workflow identity is separated from immutable semantic
  revisions, append-only typed operation batches, lifecycle events, compiled
  artifacts, derived projections, and revision-pinned runs.
  """

  import Ecto.Query

  alias RunicAI.Error
  alias RunicAI.Ids
  alias RunicAI.Persistence.JSON
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.Schemas.ManagedWorkflow
  alias RunicAI.Persistence.Schemas.ReviewRequest
  alias RunicAI.Persistence.Schemas.WorkflowCompiledArtifact
  alias RunicAI.Persistence.Schemas.WorkflowDefinitionRevision
  alias RunicAI.Persistence.Schemas.WorkflowOperationBatch
  alias RunicAI.Persistence.Schemas.WorkflowRevisionEvent
  alias RunicAI.Persistence.Schemas.WorkflowRevisionProjection
  alias RunicAI.Persistence.Schemas.WorkflowRun
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.PublicContract
  alias RunicAI.Workflows.Validator

  @type definition :: %{
          required(:workflow) => ManagedWorkflow.t(),
          required(:revision) => WorkflowDefinitionRevision.t()
        }

  @spec create_draft(Store.t(), map() | keyword()) :: {:ok, definition()} | {:error, term()}
  def create_draft(%Store{} = store, attrs) when is_list(attrs),
    do: create_draft(store, Map.new(attrs))

  def create_draft(%Store{} = store, attrs) when is_map(attrs) do
    with {:ok, ir} <- attrs |> value(:ir) |> IR.from_input() do
      transact(store, fn ->
        workflow =
          insert!(
            store,
            ManagedWorkflow.changeset(%ManagedWorkflow{}, %{
              workflow_key: value(attrs, :workflow_key) || ir.id,
              workflow_name: value(attrs, :workflow_name) || ir.objective,
              scope_type: value(attrs, :scope_type, :local),
              scope_id: value(attrs, :scope_id),
              status: :pending,
              definition_kind: :workflow_ir,
              checkpoint_strategy: value(attrs, :checkpoint_strategy, :on_complete),
              restart_policy: value(attrs, :restart_policy, :manual),
              metadata_json: value(attrs, :metadata, %{})
            })
          )

        revision =
          insert_revision!(store, workflow, ir,
            created_by: value(attrs, :actor),
            contract_hash: value(attrs, :contract_hash),
            catalog_hash: value(attrs, :catalog_hash),
            metadata: value(attrs, :revision_metadata, %{})
          )

        event = insert_revision_event!(store, workflow, revision, :drafted, attrs)

        workflow =
          update!(
            store,
            ManagedWorkflow.changeset(workflow, %{latest_revision_id: revision.id})
          )

        %{workflow: workflow, revision: revision, event: event}
      end)
    end
  end

  @spec revise(Store.t(), String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def revise(%Store{} = store, key, batch) when is_list(batch),
    do: revise(store, key, Map.new(batch))

  def revise(%Store{} = store, key, batch) when is_binary(key) and is_map(batch) do
    transact(store, fn ->
      workflow = fetch_workflow!(store, key)
      base = fetch_revision!(store, workflow.latest_revision_id)

      edit_batch = %{
        base_revision: value(batch, :base_revision),
        base_hash: value(batch, :base_hash),
        operations: value(batch, :operations, [])
      }

      edit =
        case base.ir_json |> IR.from_input() |> then_editor(edit_batch) do
          {:ok, result} -> result
          {:error, reason} -> store.repo.rollback(reason)
        end

      revision =
        insert_revision!(store, workflow, edit.ir,
          parent_revision_id: base.id,
          created_by: value(batch, :actor),
          contract_hash: value(batch, :contract_hash, base.contract_hash),
          catalog_hash: value(batch, :catalog_hash, base.catalog_hash),
          metadata: value(batch, :metadata, base.metadata_json || %{})
        )

      _cancelled_review =
        cancel_definition_review_if_pending!(store, base.id, value(batch, :actor))

      operation_batch =
        insert!(
          store,
          WorkflowOperationBatch.changeset(%WorkflowOperationBatch{}, %{
            managed_workflow_id: workflow.id,
            base_revision_id: base.id,
            result_revision_id: revision.id,
            actor: value(batch, :actor),
            base_hash: edit.base_hash,
            result_hash: edit.result_hash,
            data_json:
              Map.merge(
                %{
                  operations: edit.operations,
                  inverse_operations: edit.inverse_operations,
                  affected_nodes: edit.affected_nodes,
                  diff: edit.diff,
                  diagnostics: edit.diagnostics
                },
                value(batch, :operation_metadata, %{})
              ),
            inserted_at: DateTime.utc_now()
          })
        )

      event =
        insert_revision_event!(store, workflow, revision, :revised, %{
          actor: value(batch, :actor),
          data: %{base_revision_id: base.id, operation_batch_id: operation_batch.id}
        })

      workflow =
        update!(
          store,
          ManagedWorkflow.changeset(workflow, %{
            latest_revision_id: revision.id,
            review_revision_id: nil,
            status: if(workflow.active_revision_id, do: :active, else: :pending)
          })
        )

      %{
        workflow: workflow,
        base_revision: base,
        revision: revision,
        operation_batch: operation_batch,
        event: event,
        edit: edit,
        active_revision_unchanged?:
          is_binary(workflow.active_revision_id) and workflow.active_revision_id != revision.id
      }
    end)
  end

  @spec request_review(Store.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_review(%Store{} = store, key, opts \\ []) do
    lifecycle(store, key, :review_requested, opts, fn store, workflow, revision ->
      review = insert_definition_review!(store, workflow, revision, opts)

      workflow =
        update!(
          store,
          ManagedWorkflow.changeset(workflow, %{
            review_revision_id: revision.id,
            status: if(workflow.active_revision_id, do: :active, else: :pending)
          })
        )

      {workflow, %{review_request_id: review.id, resume_key: review.resume_key}}
    end)
  end

  @spec approve(Store.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def approve(%Store{} = store, key, opts \\ []) do
    lifecycle(store, key, :approved, opts, fn store, workflow, revision ->
      if workflow.review_revision_id == revision.id do
        review = decide_definition_review!(store, revision.id, :approved, opts)
        {workflow, %{decision: :approved, review_request_id: review.id}}
      else
        store.repo.rollback(
          Error.validation("workflow lifecycle action targets a stale revision",
            source: __MODULE__,
            details: %{
              code: :stale_lifecycle_revision,
              action: :approve,
              revision_id: revision.id,
              review_revision_id: workflow.review_revision_id
            }
          )
        )
      end
    end)
  end

  @spec reject(Store.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reject(%Store{} = store, key, opts \\ []) do
    lifecycle(store, key, :rejected, opts, fn store, workflow, revision ->
      if workflow.review_revision_id == revision.id do
        review = decide_definition_review!(store, revision.id, :denied, opts)

        workflow =
          update!(store, ManagedWorkflow.changeset(workflow, %{review_revision_id: nil}))

        {workflow, %{decision: :denied, review_request_id: review.id}}
      else
        store.repo.rollback(:no_pending_revision_review)
      end
    end)
  end

  @spec activate(Store.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def activate(%Store{} = store, key, opts \\ []) do
    lifecycle(store, key, :activated, opts, fn store, workflow, revision ->
      require_latest_action!(store, revision.id, :approved)
      artifact = latest_compiled_artifact!(store, revision.id)

      workflow =
        update!(
          store,
          ManagedWorkflow.changeset(workflow, %{
            active_revision_id: revision.id,
            review_revision_id: nil,
            status: :active,
            definition_blob: Term.to_blob(revision.ir_json)
          })
        )

      {workflow, %{compiled_artifact_id: artifact.id, compiled_hash: artifact.compiled_hash}}
    end)
  end

  @spec close(Store.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close(%Store{} = store, key, opts \\ []) do
    lifecycle(store, key, :closed, opts, fn store, workflow, _revision ->
      {update!(store, ManagedWorkflow.changeset(workflow, %{status: :disabled})), %{}}
    end)
  end

  @spec archive(Store.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def archive(%Store{} = store, key, opts \\ []) do
    lifecycle(store, key, :archived, opts, fn store, workflow, _revision ->
      {update!(store, ManagedWorkflow.changeset(workflow, %{status: :archived})), %{}}
    end)
  end

  @spec revalidate(Store.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def revalidate(%Store{} = store, key, opts \\ []) do
    transact(store, fn ->
      workflow = fetch_workflow!(store, key)
      revision = fetch_revision!(store, workflow.latest_revision_id)
      {:ok, ir} = IR.from_input(revision.ir_json)
      report = Validator.report(ir, mode: Keyword.get(opts, :mode, :runnable))

      event =
        insert_revision_event!(store, workflow, revision, :revalidated, %{
          actor: Keyword.get(opts, :actor),
          data: %{report: report, catalog_hash: Keyword.get(opts, :catalog_hash)}
        })

      %{workflow: workflow, revision: revision, report: report, event: event}
    end)
  end

  @spec catalog_migration_preview(Store.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def catalog_migration_preview(%Store{} = store, key) when is_binary(key) do
    case get(store, key) do
      %ManagedWorkflow{} = workflow ->
        case get_revision(store, workflow.latest_revision_id) do
          %WorkflowDefinitionRevision{} = base -> prepare_catalog_migration(base)
          nil -> {:error, :not_found}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @spec migrate_catalog(Store.t(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def migrate_catalog(%Store{} = store, key, attrs) when is_list(attrs),
    do: migrate_catalog(store, key, Map.new(attrs))

  def migrate_catalog(%Store{} = store, key, attrs) when is_binary(key) and is_map(attrs) do
    transact(store, fn ->
      workflow = fetch_workflow!(store, key)
      base = fetch_revision!(store, workflow.latest_revision_id)
      verify_migration_base!(store, base, attrs)

      preview =
        case prepare_catalog_migration(base) do
          {:ok, preview} -> preview
          {:error, reason} -> store.repo.rollback(reason)
        end

      expected_hash = value(attrs, :expected_semantic_hash)

      if is_binary(expected_hash) and expected_hash != preview.semantic_hash do
        store.repo.rollback(:catalog_migration_preview_changed)
      end

      compiled = value(attrs, :artifact)
      compiled_hash = value(attrs, :compiled_hash)

      unless is_binary(compiled_hash) do
        store.repo.rollback(:compiled_hash_required)
      end

      revision =
        insert_revision!(store, workflow, preview.ir,
          parent_revision_id: base.id,
          created_by: value(attrs, :actor),
          catalog_hash: preview.catalog_hash,
          metadata:
            Map.merge(base.metadata_json || %{}, %{
              "catalog_migration" => %{
                "from_catalog_hash" => base.catalog_hash,
                "to_catalog_hash" => preview.catalog_hash,
                "from_revision_id" => base.id
              }
            })
        )

      artifact =
        insert!(
          store,
          WorkflowCompiledArtifact.changeset(%WorkflowCompiledArtifact{}, %{
            revision_id: revision.id,
            compiled_hash: compiled_hash,
            catalog_hash: preview.catalog_hash,
            artifact_blob: value(attrs, :artifact_blob) || Term.to_blob(compiled),
            source_map_json: value(attrs, :source_map, %{}),
            metadata_json:
              Map.merge(value(attrs, :artifact_metadata, %{}), %{
                artifact_format: "recompile_from_ir_v1",
                compiled_hash_format: "stable_lowering_v2",
                catalog_compatibility: "strict_current_v1",
                migrated_from_artifact_id: value(attrs, :from_artifact_id)
              }),
            inserted_at: DateTime.utc_now()
          })
        )

      _cancelled_review =
        cancel_definition_review_if_pending!(store, base.id, value(attrs, :actor))

      event =
        insert_revision_event!(store, workflow, revision, :catalog_migrated, %{
          actor: value(attrs, :actor),
          data: %{
            base_revision_id: base.id,
            from_catalog_hash: base.catalog_hash,
            to_catalog_hash: preview.catalog_hash,
            compiled_artifact_id: artifact.id,
            compiled_hash: artifact.compiled_hash
          }
        })

      workflow =
        update!(
          store,
          ManagedWorkflow.changeset(workflow, %{
            latest_revision_id: revision.id,
            review_revision_id: nil,
            status: if(workflow.active_revision_id, do: :active, else: :pending)
          })
        )

      %{
        workflow: workflow,
        base_revision: base,
        revision: revision,
        artifact: artifact,
        report: preview.report,
        event: event,
        active_revision_unchanged?: workflow.active_revision_id == base.id
      }
    end)
  end

  @spec record_compilation(Store.t(), String.t(), map() | keyword()) ::
          {:ok, WorkflowCompiledArtifact.t()} | {:error, term()}
  def record_compilation(%Store{} = store, revision_id, attrs) when is_list(attrs),
    do: record_compilation(store, revision_id, Map.new(attrs))

  def record_compilation(%Store{} = store, revision_id, attrs)
      when is_binary(revision_id) and is_map(attrs) do
    artifact = value(attrs, :artifact)
    artifact_blob = value(attrs, :artifact_blob) || Term.to_blob(artifact)
    compiled_hash = value(attrs, :compiled_hash) || sha256(artifact_blob)

    transact(store, fn ->
      _revision = fetch_revision!(store, revision_id)

      insert!(
        store,
        WorkflowCompiledArtifact.changeset(%WorkflowCompiledArtifact{}, %{
          revision_id: revision_id,
          compiled_hash: compiled_hash,
          catalog_hash: value(attrs, :catalog_hash),
          artifact_blob: artifact_blob,
          source_map_json: value(attrs, :source_map, %{}),
          metadata_json: value(attrs, :metadata, %{}),
          inserted_at: DateTime.utc_now()
        })
      )
    end)
  end

  @spec put_projection(Store.t(), String.t(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, WorkflowRevisionProjection.t()} | {:error, term()}
  def put_projection(%Store{} = store, revision_id, kind, content, opts \\ [])
      when is_binary(revision_id) and is_binary(content) do
    transact(store, fn ->
      _revision = fetch_revision!(store, revision_id)

      attrs = %{
        revision_id: revision_id,
        projection_kind: kind,
        projection_hash: sha256(content),
        content: content,
        metadata_json: Keyword.get(opts, :metadata, %{}),
        inserted_at: DateTime.utc_now()
      }

      changeset = WorkflowRevisionProjection.changeset(%WorkflowRevisionProjection{}, attrs)

      case store.repo.insert(changeset,
             on_conflict: {:replace, [:projection_hash, :content, :metadata_json, :inserted_at]},
             conflict_target: [:revision_id, :projection_kind],
             returning: true
           ) do
        {:ok, projection} -> projection
        {:error, reason} -> store.repo.rollback(reason)
      end
    end)
  end

  @spec regenerate_json_projection(Store.t(), String.t()) ::
          {:ok, WorkflowRevisionProjection.t()} | {:error, term()}
  def regenerate_json_projection(%Store{} = store, revision_id) do
    case get_revision(store, revision_id) do
      %WorkflowDefinitionRevision{} = revision ->
        put_projection(store, revision.id, :json, Jason.encode!(revision.ir_json, pretty: true),
          metadata: %{regenerated_from: revision.semantic_hash}
        )

      nil ->
        {:error, :not_found}
    end
  end

  @spec launch(Store.t(), String.t(), map() | keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def launch(store, key, attrs \\ %{})

  def launch(%Store{} = store, key, attrs) when is_list(attrs),
    do: launch(store, key, Map.new(attrs))

  def launch(%Store{} = store, key, attrs) when is_binary(key) and is_map(attrs) do
    transact(store, fn ->
      workflow = fetch_workflow!(store, key)

      unless workflow.status == "active" and is_binary(workflow.active_revision_id) do
        store.repo.rollback(:no_active_revision)
      end

      revision = fetch_revision!(store, workflow.active_revision_id)
      artifact = latest_compiled_artifact!(store, revision.id)
      verify_launch_expectations!(store, attrs, revision, artifact)
      run_id = value(attrs, :id) || Ids.unique("run:#{workflow.workflow_key}")

      run =
        insert!(
          store,
          WorkflowRun.changeset(%WorkflowRun{}, %{
            id: run_id,
            workflow_key: workflow.workflow_key,
            workflow_name: workflow.workflow_name,
            workflow_id_blob: Term.to_blob(run_id),
            session_id: value(attrs, :session_id),
            managed_workflow_id: workflow.id,
            definition_revision_id: revision.id,
            definition_revision: revision.revision,
            definition_hash: revision.semantic_hash,
            compiled_artifact_id: artifact.id,
            compiled_hash: artifact.compiled_hash,
            catalog_hash: artifact.catalog_hash || revision.catalog_hash,
            status: value(attrs, :status, :pending),
            trigger: value(attrs, :trigger, :manual),
            parent_run_id: value(attrs, :parent_run_id),
            parent_node_id: value(attrs, :parent_node_id),
            invocation_key: value(attrs, :invocation_key),
            attempt: value(attrs, :attempt, 1),
            supersedes_run_id: value(attrs, :supersedes_run_id),
            input_blob: maybe_blob(value(attrs, :input)),
            output_blob: maybe_blob(value(attrs, :output)),
            metadata_json: value(attrs, :metadata, %{}),
            error_json: %{},
            started_at: value(attrs, :started_at, DateTime.utc_now())
          })
        )

      _workflow =
        update!(store, ManagedWorkflow.changeset(workflow, %{last_run_id: run.id}))

      run
    end)
  end

  @spec restart_run(Store.t(), String.t(), map() | keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def restart_run(store, run_id, attrs \\ %{})

  def restart_run(%Store{} = store, run_id, attrs) when is_list(attrs),
    do: restart_run(store, run_id, Map.new(attrs))

  def restart_run(%Store{} = store, run_id, attrs)
      when is_binary(run_id) and is_map(attrs) do
    transact(store, fn ->
      previous = store.repo.get(WorkflowRun, run_id) || store.repo.rollback(:not_found)

      unless previous.status in ["failed", "blocked", "cancelled"] do
        store.repo.rollback({:run_not_restartable, previous.status})
      end

      next_attempt = value(attrs, :attempt, (previous.attempt || 1) + 1)
      restarted_id = value(attrs, :id) || Ids.unique("run:#{previous.workflow_key}:restart")

      run =
        insert!(
          store,
          WorkflowRun.changeset(%WorkflowRun{}, %{
            id: restarted_id,
            workflow_key: previous.workflow_key,
            workflow_name: previous.workflow_name,
            workflow_id_blob: Term.to_blob(restarted_id),
            session_id: value(attrs, :session_id, previous.session_id),
            managed_workflow_id: previous.managed_workflow_id,
            definition_revision_id: previous.definition_revision_id,
            definition_revision: previous.definition_revision,
            definition_hash: previous.definition_hash,
            compiled_artifact_id: previous.compiled_artifact_id,
            compiled_hash: previous.compiled_hash,
            catalog_hash: previous.catalog_hash,
            status: :pending,
            trigger: value(attrs, :trigger, :workflow_task_retry),
            parent_run_id: value(attrs, :parent_run_id, previous.parent_run_id),
            parent_node_id: value(attrs, :parent_node_id, previous.parent_node_id),
            invocation_key: value(attrs, :invocation_key, previous.invocation_key),
            attempt: next_attempt,
            supersedes_run_id: previous.id,
            input_blob: previous.input_blob,
            metadata_json:
              Map.merge(previous.metadata_json || %{}, value(attrs, :metadata, %{}))
              |> Map.merge(%{
                "restarted_from_run_id" => previous.id,
                "attempt" => next_attempt
              }),
            error_json: %{},
            started_at: DateTime.utc_now()
          })
        )

      case store.repo.get(ManagedWorkflow, previous.managed_workflow_id) do
        %ManagedWorkflow{} = workflow ->
          update!(store, ManagedWorkflow.changeset(workflow, %{last_run_id: run.id}))

        nil ->
          :ok
      end

      run
    end)
  end

  @spec revision_change_decision(Store.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def revision_change_decision(%Store{} = store, run_id, target_revision_id) do
    SQLite.with_repo(store, fn ->
      with %WorkflowRun{} = run <- store.repo.get(WorkflowRun, run_id),
           %WorkflowDefinitionRevision{} = target <-
             store.repo.get(WorkflowDefinitionRevision, target_revision_id),
           true <- run.managed_workflow_id == target.managed_workflow_id do
        decision =
          cond do
            run.definition_revision_id == target.id -> :continue_same_revision
            run.status in ["waiting", "review", "paused"] -> :fork_or_restart_required
            run.status in ["completed", "failed", "blocked", "cancelled"] -> :new_run_required
            true -> :restart_required
          end

        {:ok,
         %{
           decision: decision,
           run_id: run.id,
           run_status: run.status,
           pinned_revision_id: run.definition_revision_id,
           target_revision_id: target.id,
           replay_current_run?: run.definition_revision_id == target.id
         }}
      else
        nil -> {:error, :not_found}
        false -> {:error, :revision_workflow_mismatch}
      end
    end)
  end

  @spec fork_run(Store.t(), String.t(), String.t(), map() | keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def fork_run(store, run_id, target_revision_id, attrs \\ %{})

  def fork_run(%Store{} = store, run_id, target_revision_id, attrs) when is_list(attrs),
    do: fork_run(store, run_id, target_revision_id, Map.new(attrs))

  def fork_run(%Store{} = store, run_id, target_revision_id, attrs)
      when is_binary(run_id) and is_binary(target_revision_id) and is_map(attrs) do
    transact(store, fn ->
      parent = store.repo.get(WorkflowRun, run_id) || store.repo.rollback(:run_not_found)
      revision = fetch_revision!(store, target_revision_id)

      if parent.managed_workflow_id != revision.managed_workflow_id do
        store.repo.rollback(:revision_workflow_mismatch)
      end

      artifact = latest_compiled_artifact!(store, revision.id)
      fork_id = value(attrs, :id) || Ids.unique("run:fork")

      insert!(
        store,
        WorkflowRun.changeset(%WorkflowRun{}, %{
          id: fork_id,
          workflow_key: parent.workflow_key,
          workflow_name: parent.workflow_name,
          workflow_id_blob: Term.to_blob(fork_id),
          session_id: value(attrs, :session_id),
          managed_workflow_id: parent.managed_workflow_id,
          definition_revision_id: revision.id,
          definition_revision: revision.revision,
          definition_hash: revision.semantic_hash,
          compiled_artifact_id: artifact.id,
          compiled_hash: artifact.compiled_hash,
          catalog_hash: artifact.catalog_hash || revision.catalog_hash,
          status: :pending,
          trigger: :fork,
          input_blob: value(attrs, :input_blob, parent.input_blob),
          metadata_json:
            Map.merge(value(attrs, :metadata, %{}), %{
              forked_from_run_id: parent.id,
              forked_from_revision_id: parent.definition_revision_id,
              fork_reason: value(attrs, :reason, "definition revision changed")
            }),
          error_json: %{},
          started_at: DateTime.utc_now()
        })
      )
    end)
  end

  @spec get(Store.t(), String.t()) :: ManagedWorkflow.t() | nil
  def get(%Store{} = store, key) do
    SQLite.with_repo(store, fn -> workflow_by_key_or_id(store, key) end)
  end

  @spec get_revision(Store.t(), String.t()) :: WorkflowDefinitionRevision.t() | nil
  def get_revision(%Store{} = store, revision_id) do
    SQLite.with_repo(store, fn -> store.repo.get(WorkflowDefinitionRevision, revision_id) end)
  end

  @spec revisions(Store.t(), String.t()) :: [WorkflowDefinitionRevision.t()]
  def revisions(%Store{} = store, key) do
    SQLite.with_repo(store, fn ->
      case workflow_by_key_or_id(store, key) do
        nil ->
          []

        workflow ->
          store.repo.all(
            from(revision in WorkflowDefinitionRevision,
              where: revision.managed_workflow_id == ^workflow.id,
              order_by: [asc: revision.revision]
            )
          )
      end
    end)
  end

  @spec events(Store.t(), String.t()) :: [WorkflowRevisionEvent.t()]
  def events(%Store{} = store, key) do
    SQLite.with_repo(store, fn ->
      case workflow_by_key_or_id(store, key) do
        nil ->
          []

        workflow ->
          store.repo.all(
            from(event in WorkflowRevisionEvent,
              where: event.managed_workflow_id == ^workflow.id,
              order_by: [asc: event.inserted_at, asc: event.id]
            )
          )
      end
    end)
  end

  @spec operation_batches(Store.t(), String.t()) :: [WorkflowOperationBatch.t()]
  def operation_batches(%Store{} = store, key) do
    SQLite.with_repo(store, fn ->
      case workflow_by_key_or_id(store, key) do
        nil ->
          []

        workflow ->
          store.repo.all(
            from(batch in WorkflowOperationBatch,
              where: batch.managed_workflow_id == ^workflow.id,
              order_by: [asc: batch.inserted_at, asc: batch.id]
            )
          )
      end
    end)
  end

  defp lifecycle(store, key, action, opts, update_fun) do
    transact(store, fn ->
      workflow = fetch_workflow!(store, key)
      revision_id = Keyword.get(opts, :revision_id, workflow.latest_revision_id)
      revision = fetch_revision!(store, revision_id)

      if revision.managed_workflow_id != workflow.id do
        store.repo.rollback(:revision_workflow_mismatch)
      end

      {workflow, data} = update_fun.(store, workflow, revision)

      event =
        insert_revision_event!(store, workflow, revision, action, %{
          actor: Keyword.get(opts, :actor),
          data: Map.merge(data, Keyword.get(opts, :data, %{}))
        })

      %{workflow: workflow, revision: revision, event: event}
    end)
  end

  defp prepare_catalog_migration(%WorkflowDefinitionRevision{} = base) do
    current_catalog_hash = Catalog.snapshot_hash()

    with true <- base.catalog_hash != current_catalog_hash || {:error, :catalog_already_current},
         {:ok, ir} <- IR.from_input(base.ir_json),
         {:ok, nodes} <- repin_nodes(ir.nodes),
         migrated = %{
           ir
           | revision: base.revision + 1,
             nodes: nodes,
             metadata:
               Map.put(ir.metadata, "catalog_migration", %{
                 "from_catalog_hash" => base.catalog_hash,
                 "to_catalog_hash" => current_catalog_hash,
                 "from_revision_id" => base.id
               })
         },
         {:ok, migrated} <- IR.validate(migrated),
         {:ok, report} <- Validator.validate(migrated, mode: :runnable) do
      {:ok,
       %{
         base_revision: base,
         ir: migrated,
         semantic_hash: IR.semantic_hash(migrated),
         catalog_hash: current_catalog_hash,
         report: report
       }}
    end
  end

  defp repin_nodes(nodes) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn {id, node}, {:ok, acc} ->
      case Catalog.resolve(node.component) do
        {:ok, contract} ->
          updated = %{node | contract: contract, effects: contract.effects}
          {:cont, {:ok, Map.put(acc, id, updated)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_migration_base!(store, base, attrs) do
    expected_id = value(attrs, :base_revision_id)
    expected_hash = value(attrs, :base_hash)

    cond do
      is_binary(expected_id) and expected_id != base.id ->
        store.repo.rollback(:stale_catalog_migration_revision)

      is_binary(expected_hash) and expected_hash != base.semantic_hash ->
        store.repo.rollback(:stale_catalog_migration_hash)

      true ->
        :ok
    end
  end

  defp insert_revision!(store, workflow, ir, opts) do
    insert!(
      store,
      WorkflowDefinitionRevision.changeset(%WorkflowDefinitionRevision{}, %{
        managed_workflow_id: workflow.id,
        revision: ir.revision,
        parent_revision_id: Keyword.get(opts, :parent_revision_id),
        semantic_hash: IR.semantic_hash(ir),
        contract_hash:
          Keyword.get(opts, :contract_hash) ||
            PublicContract.hash_for_ir(ir, Keyword.get(opts, :metadata, %{})),
        catalog_hash: Keyword.get(opts, :catalog_hash),
        ir_json: json_value(ir),
        created_by: Keyword.get(opts, :created_by),
        metadata_json: Keyword.get(opts, :metadata, %{})
      })
    )
  end

  defp insert_revision_event!(store, workflow, revision, action, attrs) do
    insert!(
      store,
      WorkflowRevisionEvent.changeset(%WorkflowRevisionEvent{}, %{
        managed_workflow_id: workflow.id,
        revision_id: revision.id,
        action: action,
        actor: value(attrs, :actor),
        data_json: value(attrs, :data, %{}),
        inserted_at: DateTime.utc_now()
      })
    )
  end

  defp latest_compiled_artifact!(store, revision_id) do
    query =
      from(artifact in WorkflowCompiledArtifact,
        where: artifact.revision_id == ^revision_id,
        order_by: [desc: artifact.inserted_at, desc: artifact.id],
        limit: 1
      )

    store.repo.one(query) || store.repo.rollback(:revision_not_compiled)
  end

  defp verify_launch_expectations!(store, attrs, revision, artifact) do
    expectations = [
      {:expected_revision_id, revision.id},
      {:expected_definition_hash, revision.semantic_hash},
      {:expected_compiled_artifact_id, artifact.id},
      {:expected_compiled_hash, artifact.compiled_hash}
    ]

    Enum.each(expectations, fn {key, actual} ->
      case value(attrs, key) do
        nil ->
          :ok

        ^actual ->
          :ok

        expected ->
          store.repo.rollback(
            Error.validation("workflow launch reference became stale before pinning",
              source: __MODULE__,
              details: %{
                code: :stale_workflow_launch_reference,
                field: key,
                expected: expected,
                actual: actual,
                revision_id: revision.id
              }
            )
          )
      end
    end)
  end

  defp insert_definition_review!(store, workflow, revision, opts) do
    resume_key = "workflow_revision:#{revision.id}"

    existing =
      store.repo.one(
        from(review in ReviewRequest,
          where: review.resume_key == ^resume_key and review.status in ["pending", "waiting"],
          limit: 1
        )
      )

    if existing do
      store.repo.rollback(:review_already_pending)
    end

    insert!(
      store,
      ReviewRequest.changeset(%ReviewRequest{}, %{
        session_id: Keyword.get(opts, :session_id),
        kind: :workflow_revision,
        checkpoint: "definition_activation",
        resume_key: resume_key,
        status: :pending,
        details_json: %{
          managed_workflow_id: workflow.id,
          workflow_key: workflow.workflow_key,
          revision_id: revision.id,
          revision: revision.revision,
          semantic_hash: revision.semantic_hash,
          requested_by: Keyword.get(opts, :actor)
        },
        decision_json: %{}
      })
    )
  end

  defp decide_definition_review!(store, revision_id, status, opts) do
    resume_key = "workflow_revision:#{revision_id}"

    review =
      store.repo.one(
        from(review in ReviewRequest,
          where: review.resume_key == ^resume_key and review.status in ["pending", "waiting"],
          order_by: [desc: review.inserted_at],
          limit: 1
        )
      ) || store.repo.rollback(:no_pending_revision_review)

    update!(
      store,
      ReviewRequest.changeset(review, %{
        status: status,
        decision_json: %{
          decision: status,
          actor: Keyword.get(opts, :actor),
          reason: Keyword.get(opts, :reason),
          decided_at: DateTime.utc_now()
        }
      })
    )
  end

  defp cancel_definition_review_if_pending!(store, revision_id, actor) do
    resume_key = "workflow_revision:#{revision_id}"

    case store.repo.one(
           from(review in ReviewRequest,
             where: review.resume_key == ^resume_key and review.status in ["pending", "waiting"],
             order_by: [desc: review.inserted_at],
             limit: 1
           )
         ) do
      %ReviewRequest{} = review ->
        update!(
          store,
          ReviewRequest.changeset(review, %{
            status: :cancelled,
            decision_json: %{
              decision: :cancelled,
              actor: actor,
              reason: "superseded by a newer immutable workflow revision",
              decided_at: DateTime.utc_now()
            }
          })
        )

      nil ->
        nil
    end
  end

  defp require_latest_action!(store, revision_id, expected) do
    expected = to_string(expected)

    query =
      from(event in WorkflowRevisionEvent,
        where: event.revision_id == ^revision_id,
        order_by: [desc: event.inserted_at, desc: event.id],
        limit: 1,
        select: event.action
      )

    case store.repo.one(query) do
      ^expected -> :ok
      action -> store.repo.rollback({:invalid_lifecycle_transition, action, expected})
    end
  end

  defp fetch_workflow!(store, key) do
    workflow_by_key_or_id(store, key) || store.repo.rollback(:not_found)
  end

  defp workflow_by_key_or_id(store, key) do
    store.repo.get(ManagedWorkflow, key) ||
      store.repo.get_by(ManagedWorkflow, workflow_key: key)
  end

  defp fetch_revision!(store, nil), do: store.repo.rollback(:no_revision)

  defp fetch_revision!(store, id) do
    store.repo.get(WorkflowDefinitionRevision, id) || store.repo.rollback(:revision_not_found)
  end

  defp insert!(store, changeset) do
    case store.repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> store.repo.rollback(reason)
    end
  end

  defp update!(store, changeset) do
    case store.repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> store.repo.rollback(reason)
    end
  end

  defp transact(store, fun) do
    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn -> store.repo.transaction(fun) end)
    end)
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp then_editor({:ok, ir}, batch), do: Editor.apply(ir, batch)
  defp then_editor({:error, reason}, _batch), do: {:error, reason}

  defp json_value(value) do
    value |> Jason.encode!() |> Jason.decode!()
  rescue
    _error -> JSON.safe(value)
  end

  defp maybe_blob(nil), do: nil
  defp maybe_blob(value), do: Term.to_blob(value)

  defp sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp value(input, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(list, key, default) when is_list(list), do: Keyword.get(list, key, default)
end
