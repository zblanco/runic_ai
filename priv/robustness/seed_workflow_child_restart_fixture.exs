alias RunicAI.Coding.Workspace
alias RunicAI.Persistence.WorkflowDefinitions
alias RunicAI.Workbench
alias RunicAI.Workflows.Catalog
alias RunicAI.Workflows.Compiler
alias RunicAI.Workflows.IR
alias RunicAI.Workflows.IR.Node

suffix =
  System.get_env("RUNIC_AI_FIXTURE_SUFFIX") ||
    Integer.to_string(System.unique_integer([:positive]))

session_id = "browser-child-restart-#{suffix}"
workflow_key = "browser-child-restart-#{suffix}"
parent_run_id = "run:#{session_id}:parent"
failed_run_id = "run:#{session_id}:child:1"
store = Workbench.store!()
now = DateTime.utc_now()

record_event = fn attrs ->
  Workbench.record_terminal_event(
    Map.merge(
      %{
        id: "fixture:child-restart:event:#{System.unique_integer([:positive])}",
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        at: now
      },
      attrs
    )
  )
end

{:ok, _event} =
  record_event.(%{
    kind: :status,
    phase: :session,
    status: :running,
    title: "Selective child restart fixture ready",
    detail: "Restart one failed child without replaying completed siblings",
    data_json: %{
      run_id: session_id,
      cwd: File.cwd!(),
      objective: "Prove durable selective child retry through the Workbench",
      model: "openai:gpt-5.6-luna"
    }
  })

{:ok, discover} =
  Node.new("discover_fixture_source", :source_discovery,
    arguments: %{paths: ["mix.exs"], max_depth: 1, max_files: 4}
  )

{:ok, ir} =
  IR.new("workflow:#{workflow_key}", "Discover one fixture source",
    nodes: %{discover.id => discover},
    acceptance: [%{id: "source discovered", required: true}]
  )

public_contract = %{
  inputs: %{type: "object"},
  outputs: %{type: "object"},
  effects: [],
  policies: %{max_runtime_ms: 10_000},
  acceptance: [%{id: "source discovered", required: true}]
}

workspace = Workspace.new!(root: File.cwd!())
catalog_hash = Catalog.snapshot_hash()

{:ok, created} =
  WorkflowDefinitions.create_draft(store,
    workflow_key: workflow_key,
    workflow_name: "Selective child restart fixture",
    ir: ir,
    revision_metadata: %{public_contract: public_contract},
    catalog_hash: catalog_hash
  )

{:ok, compiled} = Compiler.compile(created.revision.ir_json, workspace)

{:ok, artifact} =
  WorkflowDefinitions.record_compilation(store, created.revision.id, %{
    artifact: compiled,
    compiled_hash: compiled.compiled_hash,
    catalog_hash: catalog_hash,
    source_map: compiled.source_map,
    metadata: %{
      compiled_by: "child-restart-browser-fixture",
      artifact_format: "recompile_from_ir_v1",
      compiled_hash_format: "stable_lowering_v2"
    }
  })

{:ok, _review} = WorkflowDefinitions.request_review(store, workflow_key)
{:ok, _approval} = WorkflowDefinitions.approve(store, workflow_key)
{:ok, _activation} = WorkflowDefinitions.activate(store, workflow_key)

{:ok, parent} =
  WorkflowDefinitions.launch(store, workflow_key, %{
    id: parent_run_id,
    session_id: session_id,
    status: :running,
    trigger: :browser_fixture,
    input: %{}
  })

{:ok, failed_child} =
  WorkflowDefinitions.launch(store, workflow_key, %{
    id: failed_run_id,
    session_id: session_id,
    status: :failed,
    trigger: :workflow_task,
    input: %{},
    parent_run_id: parent.id,
    parent_node_id: "discover_saved_sources",
    invocation_key: "fixture:#{session_id}:discover",
    attempt: 1,
    metadata: %{
      parent_run_id: parent.id,
      parent_node_id: "discover_saved_sources",
      invocation_key: "fixture:#{session_id}:discover",
      model: "openai:gpt-5.6-luna"
    }
  })

{:ok, _event} =
  record_event.(%{
    kind: :summary,
    phase: :final,
    status: :ok,
    title: "Agent finished",
    detail: "A failed pinned child is ready for selective restart",
    data_json: %{run_id: failed_child.id, workflow_key: workflow_key}
  })

IO.puts(
  Jason.encode!(%{
    session_id: session_id,
    workflow_key: workflow_key,
    parent_run_id: parent.id,
    failed_run_id: failed_child.id,
    definition_hash: created.revision.semantic_hash,
    compiled_hash: artifact.compiled_hash,
    catalog_hash: artifact.catalog_hash
  })
)
