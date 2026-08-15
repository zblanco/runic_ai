defmodule RunicAI.Workflows.IntentRouterTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.IntentRouter

  setup do
    {:ok, store} = SQLite.open(":memory:")
    on_exit(fn -> SQLite.close(store) end)
    seed_active_workflow(store)
    %{store: store}
  end

  test "routes simple conversation directly and honors an explicit workflow request", %{
    store: store
  } do
    assert {:ok, direct} = IntentRouter.route(store, %{objective: "Tell me a joke"})
    assert direct.strategy == :direct
    assert :no_orchestration_intent_signal in direct.reasons

    assert {:ok, forced} =
             IntentRouter.route(store, %{objective: "Tell me a joke"}, strategy: :workflow)

    assert forced.strategy == :draft
  end

  test "distinguishes exact reuse, adaptation, and a new draft", %{store: store} do
    assert {:ok, exact} =
             IntentRouter.route(store, %{
               objective: "Analyze support tickets",
               input: %{tickets: []}
             })

    assert exact.strategy == :reuse_exact
    assert exact.selected.reference.workflow_key == "analyze-support-tickets"

    assert {:ok, adapt} =
             IntentRouter.route(store, %{
               objective: "Analyze customer invoices",
               input: %{tickets: []}
             })

    assert adapt.strategy == :adapt
    assert adapt.selected.objective_similarity > 0.2

    assert {:ok, draft} =
             IntentRouter.route(store, %{
               objective: "Compile repository release notes",
               input: %{repository: "."}
             })

    assert draft.strategy == :draft
    assert draft.selected == nil
    assert [%{compatible?: false}] = draft.candidates
  end

  test "does not reuse an active revision without declared public input evidence", %{
    store: store
  } do
    {:ok, node} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:write-risk-report", "Write a delivery risk report",
        nodes: %{node.id => node}
      )

    {:ok, created} =
      WorkflowDefinitions.create_draft(store,
        workflow_key: "write-risk-report",
        workflow_name: "Write a delivery risk report",
        ir: ir,
        catalog_hash: "catalog:intent-router:v1"
      )

    native = Workflow.new(name: :undeclared_contract_fixture)

    {:ok, _artifact} =
      WorkflowDefinitions.record_compilation(store, created.revision.id, %{
        artifact: %{workflow: native},
        compiled_hash: "compiled:undeclared-contract:v1",
        catalog_hash: "catalog:intent-router:v1"
      })

    {:ok, _review} = WorkflowDefinitions.request_review(store, created.workflow.id)
    {:ok, _approval} = WorkflowDefinitions.approve(store, created.workflow.id)
    {:ok, _activation} = WorkflowDefinitions.activate(store, created.workflow.id)

    assert {:ok, routed} =
             IntentRouter.route(store, %{
               objective: "Write a delivery risk report",
               input_paths: ["notes/incidents.md"],
               output_path: ".docs/risk-report.md"
             })

    assert routed.strategy == :draft

    assert Enum.any?(routed.candidates, fn candidate ->
             candidate.workflow.workflow_key == "write-risk-report" and
               candidate.compatible? == false and
               candidate.adaptable? == false and
               match?(
                 {:error,
                  %RunicAI.Error{
                    details: %{code: :workflow_public_input_contract_undeclared}
                  }},
                 candidate.compatibility
               )
           end)
  end

  test "does not execute or adapt a high-overlap workflow when intent risk changes", %{
    store: store
  } do
    assert {:ok, negated} =
             IntentRouter.route(store, %{
               objective: "Do not analyze support tickets",
               input: %{tickets: []}
             })

    assert negated.strategy == :draft
    assert negated.selected == nil

    assert [candidate | _rest] = negated.candidates
    assert candidate.objective_similarity >= 0.75
    assert candidate.compatibility == :ok
    assert candidate.adaptation_compatibility == :ok
    assert candidate.compatible?
    refute candidate.exact_reuse?
    refute candidate.adaptable?
    refute candidate.exact_objective?
    refute candidate.intent_compatible?
    assert :intent_risk_mismatch in candidate.reasons

    assert {:ok, destructive} =
             IntentRouter.route(store, %{
               objective: "Delete analyzed support tickets",
               input: %{tickets: []}
             })

    assert destructive.strategy == :draft
    assert destructive.selected == nil
  end

  defp seed_active_workflow(store) do
    {:ok, node} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:analyze-support-tickets", "Analyze support tickets",
        nodes: %{node.id => node},
        acceptance: [%{id: "tickets_analyzed", required: true}]
      )

    public_contract = %{
      inputs: %{
        type: "object",
        required: ["tickets"],
        properties: %{"tickets" => %{type: "array"}}
      },
      outputs: %{type: "object"},
      effects: [],
      policies: %{},
      acceptance: [%{id: "tickets_analyzed", required: true}]
    }

    {:ok, created} =
      WorkflowDefinitions.create_draft(store,
        workflow_key: "analyze-support-tickets",
        workflow_name: "Analyze support tickets",
        ir: ir,
        revision_metadata: %{public_contract: public_contract},
        catalog_hash: "catalog:intent-router:v1"
      )

    native = Workflow.new(name: :intent_router_fixture)

    {:ok, _artifact} =
      WorkflowDefinitions.record_compilation(store, created.revision.id, %{
        artifact: %{workflow: native},
        compiled_hash: "compiled:intent-router:v1",
        catalog_hash: "catalog:intent-router:v1"
      })

    {:ok, _review} = WorkflowDefinitions.request_review(store, created.workflow.id)
    {:ok, _approval} = WorkflowDefinitions.approve(store, created.workflow.id)
    {:ok, _activation} = WorkflowDefinitions.activate(store, created.workflow.id)
  end
end
