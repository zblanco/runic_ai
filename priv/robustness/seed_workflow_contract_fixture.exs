alias RunicAI.Persistence.WorkflowDefinitions
alias RunicAI.Workbench
alias RunicAI.Workflows.IR
alias RunicAI.Workflows.IR.Edge
alias RunicAI.Workflows.IR.Node

suffix =
  System.get_env("RUNIC_AI_FIXTURE_SUFFIX") ||
    Integer.to_string(System.unique_integer([:positive]))

session_id = "browser-contract-lineage-#{suffix}"
workflow_key = "browser-contract-lineage-#{suffix}"
store = Workbench.store!()
now = DateTime.utc_now()

record_event = fn attrs ->
  Workbench.record_terminal_event(
    Map.merge(
      %{
        id: "fixture:event:#{suffix}:#{System.unique_integer([:positive])}",
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
    title: "Workbench run queued",
    detail: "Inspect a human-readable workflow contract and its exact runtime lineage",
    data_json: %{
      run_id: session_id,
      cwd: File.cwd!(),
      objective: "Inspect a human-readable workflow contract and its exact runtime lineage",
      model: "openai:gpt-5.6-luna"
    }
  })

{:ok, _event} =
  record_event.(%{
    kind: :rlm_plan,
    phase: :compile_completed,
    status: :ok,
    title: "RLM Compile completed",
    detail: "workflow compiled through the canonical IR",
    data_json: %{
      compiled: %{
        metadata: %{source_count: 2},
        graph_summary: %{
          runic: %{
            native_nodes: [
              %{
                name: "acceptance_contract",
                kind: "deterministic_step",
                execution_shape: "step",
                inputs: %{"context" => %{contract: %{type: "object"}}},
                outputs: %{"context" => %{contract: %{type: "object"}}},
                policy: %{},
                metadata: %{
                  workflow_ir_effects: [],
                  workflow_ir_replay: %{strategy: :safe_replay, automatic_retry?: true}
                }
              },
              %{
                name: "compile_project",
                kind: "command",
                execution_shape: "side_effect_step",
                inputs: %{"context" => %{contract: %{type: "object"}}},
                outputs: %{"context" => %{contract: %{type: "object"}}},
                policy: %{review: "safe"},
                metadata: %{
                  workflow_ir_effects: ["workspace_write"],
                  workflow_ir_replay: %{
                    strategy: :manual_reconciliation,
                    automatic_retry?: false
                  }
                }
              }
            ],
            edgelist: [%{from: "acceptance_contract", to: "compile_project"}],
            serializers: %{
              mermaid:
                "flowchart TB\n  acceptance_contract[\"acceptance_contract\"] --> compile_project[\"compile_project\"]"
            }
          },
          stop_conditions: ["compile passes"]
        }
      }
    }
  })

{:ok, discover} = Node.new("acceptance_contract", :source_discovery)
{:ok, compile} = Node.new("compile_project", :source_splitter)

{:ok, edge} =
  Edge.new(
    %{node: discover.id, port: "out"},
    %{node: compile.id, port: "in"}
  )

{:ok, ir} =
  IR.new("workflow:#{workflow_key}", "Inspect workflow contract lineage",
    nodes: %{discover.id => discover, compile.id => compile},
    edges: %{edge.id => edge},
    acceptance: [%{id: "compile passes", required: true}]
  )

{:ok, created} =
  WorkflowDefinitions.create_draft(store,
    workflow_key: workflow_key,
    workflow_name: "Contract lineage fixture",
    ir: ir,
    catalog_hash: "catalog-lineage-luna-v1"
  )

{:ok, artifact} =
  WorkflowDefinitions.record_compilation(store, created.revision.id, %{
    artifact: %{runtime: :runic, ir_id: ir.id},
    compiled_hash: "compiled-lineage-luna-v1",
    catalog_hash: "catalog-lineage-luna-v1"
  })

{:ok, _review} = WorkflowDefinitions.request_review(store, workflow_key)
{:ok, _approval} = WorkflowDefinitions.approve(store, workflow_key)
{:ok, _activation} = WorkflowDefinitions.activate(store, workflow_key)

{:ok, run} =
  WorkflowDefinitions.launch(store, workflow_key, %{
    id: "run:#{session_id}",
    session_id: session_id,
    status: :completed,
    trigger: :browser_fixture
  })

{:ok, _event} =
  record_event.(%{
    kind: :summary,
    phase: :final,
    status: :ok,
    title: "Agent finished",
    detail: "Compiled workflow contract is ready for inspection",
    data_json: %{run_id: run.id, workflow_key: workflow_key}
  })

IO.puts(
  Jason.encode!(%{
    session_id: session_id,
    workflow_key: workflow_key,
    definition_hash: created.revision.semantic_hash,
    compiled_hash: artifact.compiled_hash,
    catalog_hash: artifact.catalog_hash
  })
)
