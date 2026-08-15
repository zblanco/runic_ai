defmodule RunicAI.Persistence.WorkflowDefinitionsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Error
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.ManagedWorkflows
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Node

  setup do
    {:ok, store} = SQLite.open(":memory:")
    on_exit(fn -> SQLite.close(store) end)
    %{store: store}
  end

  test "drafts and revises immutable canonical definitions with append-only operations", %{
    store: store
  } do
    ir = workflow_ir()

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store, %{
               workflow_key: "research-flow",
               workflow_name: "Research flow",
               ir: ir,
               actor: "agent:planner",
               catalog_hash: "catalog:v1"
             })

    assert created.workflow.status == "pending"
    assert created.workflow.latest_revision_id == created.revision.id
    assert created.revision.revision == 1
    assert created.revision.semantic_hash == IR.semantic_hash(ir)
    assert created.event.action == "drafted"

    batch = %{
      base_revision: 1,
      base_hash: created.revision.semantic_hash,
      actor: "human:operator",
      operations: [%{op: "set_policy", key: "max_runtime_ms", value: 60_000}]
    }

    assert {:ok, revised} = WorkflowDefinitions.revise(store, "research-flow", batch)
    assert revised.base_revision.id == created.revision.id
    assert revised.revision.revision == 2
    assert revised.revision.parent_revision_id == created.revision.id
    assert revised.operation_batch.base_hash == created.revision.semantic_hash
    assert revised.operation_batch.result_hash == revised.revision.semantic_hash
    assert revised.edit.ir.policies["max_runtime_ms"] == 60_000

    assert [first, second] = WorkflowDefinitions.revisions(store, "research-flow")
    assert first.ir_json["policies"] == %{}
    assert second.ir_json["policies"]["max_runtime_ms"] == 60_000

    assert [operation_batch] = WorkflowDefinitions.operation_batches(store, "research-flow")

    assert operation_batch.data_json["operations"] == [
             %{"key" => "max_runtime_ms", "op" => "set_policy", "value" => 60_000}
           ]

    assert {:error, %Error{details: %{code: :stale_revision}}} =
             WorkflowDefinitions.revise(store, "research-flow", batch)

    assert length(WorkflowDefinitions.revisions(store, "research-flow")) == 2
    assert length(WorkflowDefinitions.operation_batches(store, "research-flow")) == 1
  end

  test "reviewed active revisions launch with immutable definition and compilation pins", %{
    store: store
  } do
    ir = workflow_ir()

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: "launchable-flow",
               ir: ir,
               actor: "agent:planner",
               catalog_hash: "catalog:v1"
             )

    assert {:ok, compiled} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{runtime: :runic, nodes: ["discover"]},
               compiled_hash: "compiled:v1",
               catalog_hash: "catalog:v1",
               source_map: %{"discover" => ["runic:discover"]}
             })

    assert {:ok, review} =
             WorkflowDefinitions.request_review(store, "launchable-flow", actor: "agent:planner")

    assert review.workflow.review_revision_id == created.revision.id

    assert {:ok, approved} =
             WorkflowDefinitions.approve(store, "launchable-flow", actor: "human:operator")

    assert approved.event.action == "approved"

    assert {:ok, activated} =
             WorkflowDefinitions.activate(store, "launchable-flow", actor: "human:operator")

    assert activated.workflow.status == "active"
    assert activated.workflow.active_revision_id == created.revision.id

    assert {:ok, run} =
             WorkflowDefinitions.launch(store, "launchable-flow", %{
               id: "run:launchable:1",
               session_id: "session:launchable:1",
               input: %{query: "durable workflows"},
               status: :waiting
             })

    assert run.definition_revision_id == created.revision.id
    assert run.definition_revision == 1
    assert run.definition_hash == created.revision.semantic_hash
    assert run.compiled_artifact_id == compiled.id
    assert run.compiled_hash == "compiled:v1"
    assert run.catalog_hash == "catalog:v1"

    assert {:ok, bridged_run} =
             ManagedWorkflows.create_run(store, "launchable-flow", %{
               id: "run:launchable:managed-api"
             })

    assert bridged_run.definition_revision_id == created.revision.id
    assert bridged_run.compiled_artifact_id == compiled.id

    assert {:ok, revised} =
             WorkflowDefinitions.revise(store, "launchable-flow", %{
               base_revision: 1,
               base_hash: created.revision.semantic_hash,
               operations: [%{op: "set_policy", key: "max_cost_usd", value: 1.5}]
             })

    assert revised.active_revision_unchanged? == true
    assert revised.workflow.active_revision_id == created.revision.id
    assert revised.workflow.latest_revision_id == revised.revision.id

    assert {:ok, decision} =
             WorkflowDefinitions.revision_change_decision(
               store,
               run.id,
               revised.revision.id
             )

    assert decision.decision == :fork_or_restart_required
    assert decision.pinned_revision_id == created.revision.id

    assert {:ok, revised_compilation} =
             WorkflowDefinitions.record_compilation(store, revised.revision.id, %{
               artifact: %{runtime: :runic, nodes: ["discover"], revision: 2},
               compiled_hash: "compiled:v2",
               catalog_hash: "catalog:v1"
             })

    assert {:ok, forked} =
             WorkflowDefinitions.fork_run(store, run.id, revised.revision.id, %{
               id: "run:launchable:fork",
               reason: "operator selected fork after reviewing revision diff"
             })

    assert forked.definition_revision_id == revised.revision.id
    assert forked.compiled_artifact_id == revised_compilation.id
    assert forked.metadata_json["forked_from_run_id"] == run.id
    assert forked.metadata_json["forked_from_revision_id"] == created.revision.id

    assert {:ok, still_pinned} =
             WorkflowDefinitions.launch(store, "launchable-flow", %{id: "run:launchable:2"})

    assert still_pinned.definition_revision_id == created.revision.id
    assert still_pinned.compiled_artifact_id == compiled.id
  end

  test "a newer immutable revision invalidates approval of the reviewed revision", %{store: store} do
    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: "stale-approval-flow",
               ir: workflow_ir(),
               actor: "agent:planner"
             )

    assert {:ok, reviewed} =
             WorkflowDefinitions.request_review(store, "stale-approval-flow",
               actor: "agent:planner"
             )

    assert reviewed.workflow.review_revision_id == created.revision.id

    assert {:ok, revised} =
             WorkflowDefinitions.revise(store, "stale-approval-flow", %{
               base_revision: created.revision.revision,
               base_hash: created.revision.semantic_hash,
               actor: "agent:planner",
               operations: [%{op: "set_policy", key: "max_runtime_ms", value: 30_000}]
             })

    assert revised.workflow.review_revision_id == nil

    assert {:error,
            %Error{
              details: %{
                code: :stale_lifecycle_revision,
                action: :approve,
                revision_id: revision_id,
                review_revision_id: nil
              }
            }} =
             WorkflowDefinitions.approve(store, "stale-approval-flow", actor: "human:operator")

    assert revision_id == revised.revision.id
    assert WorkflowDefinitions.get(store, "stale-approval-flow").active_revision_id == nil
  end

  test "canonical projections regenerate and lifecycle survives reopening SQLite" do
    root =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-workflow-definitions-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    path = Path.join(root, "runs.db")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, store} = SQLite.open(path)

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: "restartable-flow",
               ir: workflow_ir(),
               actor: "agent:planner"
             )

    assert {:ok, projection} =
             WorkflowDefinitions.regenerate_json_projection(store, created.revision.id)

    assert projection.projection_kind == "json"
    assert projection.content =~ "restartable"
    assert {:ok, _review} = WorkflowDefinitions.request_review(store, "restartable-flow")
    :ok = SQLite.close(store)

    {:ok, reopened} = SQLite.open(path)
    on_exit(fn -> SQLite.close(reopened) end)

    workflow = WorkflowDefinitions.get(reopened, "restartable-flow")
    revision = WorkflowDefinitions.get_revision(reopened, workflow.latest_revision_id)
    events = WorkflowDefinitions.events(reopened, "restartable-flow")

    assert revision.semantic_hash == created.revision.semantic_hash
    assert workflow.review_revision_id == revision.id
    assert Enum.map(events, & &1.action) == ["drafted", "review_requested"]
    assert {:ok, %IR{id: "workflow:restartable"}} = IR.from_input(revision.ir_json)

    assert {:ok, approved} =
             WorkflowDefinitions.approve(reopened, "restartable-flow",
               actor: "human:after-restart"
             )

    assert approved.event.action == "approved"
    assert approved.event.data_json["review_request_id"]
  end

  test "catalog migration creates a reviewed immutable revision and forks without rewriting pins",
       %{
         store: store
       } do
    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: "catalog-migration",
               ir: workflow_ir(),
               catalog_hash: "retired-catalog"
             )

    assert {:ok, old_artifact} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{runtime: :legacy},
               compiled_hash: "compiled:legacy",
               catalog_hash: "retired-catalog"
             })

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, "catalog-migration")
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, "catalog-migration")
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, "catalog-migration")

    assert {:ok, old_run} =
             WorkflowDefinitions.launch(store, "catalog-migration", %{
               id: "run:catalog-migration:old",
               status: :completed
             })

    assert {:ok, preview} =
             WorkflowDefinitions.catalog_migration_preview(store, "catalog-migration")

    assert preview.base_revision.id == created.revision.id
    assert preview.ir.revision == 2
    assert preview.catalog_hash == Catalog.snapshot_hash()
    assert preview.ir.nodes["discover"].contract.ref =~ "@2"

    assert {:ok, migrated} =
             WorkflowDefinitions.migrate_catalog(store, "catalog-migration", %{
               base_revision_id: created.revision.id,
               base_hash: created.revision.semantic_hash,
               expected_semantic_hash: preview.semantic_hash,
               artifact: %{runtime: :recompiled},
               compiled_hash: "compiled:current",
               actor: "human:migrator"
             })

    assert migrated.revision.revision == 2
    assert migrated.revision.parent_revision_id == created.revision.id
    assert migrated.revision.catalog_hash == Catalog.snapshot_hash()
    assert migrated.artifact.catalog_hash == Catalog.snapshot_hash()
    assert migrated.artifact.metadata_json["catalog_compatibility"] == "strict_current_v1"
    assert migrated.event.action == "catalog_migrated"
    assert migrated.workflow.active_revision_id == created.revision.id
    assert migrated.active_revision_unchanged?
    assert old_run.compiled_artifact_id == old_artifact.id

    assert {:error, :catalog_already_current} =
             WorkflowDefinitions.catalog_migration_preview(store, "catalog-migration")

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, "catalog-migration")
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, "catalog-migration")
    assert {:ok, activated} = WorkflowDefinitions.activate(store, "catalog-migration")
    assert activated.workflow.active_revision_id == migrated.revision.id

    assert {:ok, forked} =
             WorkflowDefinitions.fork_run(store, old_run.id, migrated.revision.id, %{
               id: "run:catalog-migration:fork"
             })

    assert forked.definition_revision_id == migrated.revision.id
    assert forked.compiled_artifact_id == migrated.artifact.id
    assert old_run.definition_revision_id == created.revision.id
  end

  defp workflow_ir do
    {:ok, discover} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:restartable", "Research durable workflow definitions",
        nodes: %{discover.id => discover},
        acceptance: [%{id: "grounded", required: true}]
      )

    ir
  end
end
