alias RunicAI.Coding.Workspace
alias RunicAI.Persistence.WorkflowDefinitions
alias RunicAI.Workbench
alias RunicAI.Workflows.Compiler
alias RunicAI.Workflows.IR
alias RunicAI.Workflows.IR.Edge
alias RunicAI.Workflows.IR.Node

suffix =
  System.get_env("RUNIC_AI_FIXTURE_SUFFIX") ||
    Integer.to_string(System.unique_integer([:positive]))

session_id = "browser-runtime-review-#{suffix}"
workflow_key = "browser-runtime-review-#{suffix}"
run_id = "run:#{session_id}"
store = Workbench.store!()
now = DateTime.utc_now()

record_event = fn attrs ->
  Workbench.record_terminal_event(
    Map.merge(
      %{
        id: "fixture:runtime-review:event:#{System.unique_integer([:positive])}",
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
    title: "Workbench runtime-review fixture queued",
    detail: "Start a pinned run, pause it for review, restart, and resume it",
    data_json: %{
      run_id: session_id,
      cwd: File.cwd!(),
      objective: "Prove a durable runtime review across process restart",
      model: "openai:gpt-5.6-luna"
    }
  })

{:ok, discover} =
  Node.new("discover_workspace", :source_discovery,
    arguments: %{sources: ["."], max_depth: 8, max_files: 512}
  )

{:ok, split} =
  Node.new("split_sources", :source_splitter, arguments: %{max_sources: 128, max_bytes: 16_000})

{:ok, materialize} =
  Node.new("materialize_sources", :source_materializer, arguments: %{max_total_bytes: 512_000})

{:ok, discovery_edge} =
  Edge.new(%{node: discover.id, port: "out"}, %{node: split.id, port: "in"})

{:ok, materialize_edge} =
  Edge.new(%{node: split.id, port: "out"}, %{node: materialize.id, port: "in"})

{:ok, ir} =
  IR.new("workflow:#{workflow_key}", "Prove a durable runtime review",
    nodes: %{discover.id => discover, split.id => split, materialize.id => materialize},
    edges: %{
      discovery_edge.id => discovery_edge,
      materialize_edge.id => materialize_edge
    },
    acceptance: [%{"id" => "operator approved", "required" => true}]
  )

{:ok, workspace} = Workspace.new(root: File.cwd!())
{:ok, compiled} = Compiler.compile(ir, workspace)

{:ok, created} =
  WorkflowDefinitions.create_draft(store,
    workflow_key: workflow_key,
    workflow_name: "Durable runtime review fixture",
    ir: ir,
    catalog_hash: "catalog-runtime-review-luna-v1"
  )

{:ok, artifact} =
  WorkflowDefinitions.record_compilation(store, created.revision.id, %{
    artifact: compiled,
    compiled_hash: compiled.compiled_hash,
    catalog_hash: "catalog-runtime-review-luna-v1",
    source_map: compiled.source_map,
    metadata: %{
      compiled_by: "runtime-review-fixture",
      artifact_format: "recompile_from_ir_v1",
      compiled_hash_format: "stable_lowering_v2"
    }
  })

{:ok, _review} = WorkflowDefinitions.request_review(store, workflow_key)
{:ok, _approval} = WorkflowDefinitions.approve(store, workflow_key)
{:ok, _activation} = WorkflowDefinitions.activate(store, workflow_key)

{:ok, run} =
  WorkflowDefinitions.launch(store, workflow_key, %{
    id: run_id,
    session_id: session_id,
    status: :pending,
    trigger: :browser_fixture,
    input: %{}
  })

{:ok, _event} =
  record_event.(%{
    kind: :summary,
    phase: :final,
    status: :ok,
    title: "Runtime-review fixture ready",
    detail: "The pinned workflow is pending operator start",
    data_json: %{run_id: run.id, workflow_key: workflow_key}
  })

IO.puts(
  Jason.encode!(%{
    session_id: session_id,
    workflow_key: workflow_key,
    run_id: run.id,
    definition_hash: created.revision.semantic_hash,
    compiled_hash: artifact.compiled_hash
  })
)
