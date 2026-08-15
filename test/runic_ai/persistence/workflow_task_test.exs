defmodule RunicAI.Persistence.WorkflowTaskTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Error
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.RunnerStore
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Persistence.WorkflowLibrary
  alias RunicAI.Persistence.WorkflowTask
  alias RunicAI.RLM.ComponentCatalog
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Node

  setup do
    {:ok, store} = SQLite.open(":memory:")
    on_exit(fn -> SQLite.close(store) end)
    %{store: store}
  end

  test "rejects incompatible reuse before launch and records an exact child run", %{store: store} do
    assert {:ok, catalog_contract} = Catalog.resolve(:workflow_task)
    assert catalog_contract.execution_shape == :side_effect_step
    assert catalog_contract.effects == [:workflow_invoke]

    assert {:ok, workflow_task_spec} =
             ComponentCatalog.spec_from_blueprint(%{
               id: "invoke_increment",
               type: :workflow_task,
               params: %{workflow_key: "increment", revision: 1}
             })

    assert workflow_task_spec.type == :workflow_task

    {:ok, discover} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:increment", "Increment a supplied integer",
        nodes: %{discover.id => discover},
        acceptance: [%{id: "incremented", required: true}]
      )

    public_contract = %{
      inputs: %{
        type: "object",
        required: ["n"],
        properties: %{"n" => %{type: "integer"}}
      },
      outputs: %{type: "integer"},
      effects: [],
      policies: %{max_runtime_ms: 5_000},
      acceptance: [%{id: "incremented", required: true}]
    }

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: "increment",
               workflow_name: "Increment integer",
               ir: ir,
               revision_metadata: %{public_contract: public_contract},
               catalog_hash: "catalog:reuse:v1"
             )

    native_workflow =
      Workflow.new(name: :reusable_increment)
      |> Workflow.add(Runic.step(fn %{n: n} -> n + 1 end, name: :increment))

    assert {:ok, artifact} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{workflow: native_workflow},
               compiled_hash: "compiled:reuse:v1",
               catalog_hash: "catalog:reuse:v1"
             })

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, "increment")
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, "increment")
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, "increment")

    assert {:ok, resolved} = WorkflowLibrary.resolve(store, "increment@1")
    assert resolved.contract.contract_hash == created.revision.contract_hash
    assert resolved.reference.definition_hash == created.revision.semantic_hash

    retrieval = WorkflowLibrary.retrieve(store, "increment an integer", %{n: 3})
    assert retrieval.decision == :reuse_exact
    assert retrieval.selected.reference.revision == 1
    assert retrieval.selected.objective_similarity == 1.0
    assert :input_contract_compatible in retrieval.selected.reasons

    adaptation = WorkflowLibrary.retrieve(store, "increment a collection", %{n: 3})
    assert adaptation.decision == :adapt
    assert adaptation.selected.reference.revision == 1
    assert adaptation.selected.objective_similarity == 0.5

    miss = WorkflowLibrary.retrieve(store, "summarize support tickets", %{n: 3})
    assert miss.decision == :miss
    assert miss.selected == nil
    assert [%{compatible?: true, objective_similarity: similarity}] = miss.candidates
    assert similarity == 0

    assert {:ok, parent} =
             WorkflowDefinitions.launch(store, "increment", %{
               id: "run:reuse-parent",
               session_id: "session:reuse",
               status: :running
             })

    runner =
      Module.concat([__MODULE__, :"Runner#{System.unique_integer([:positive])}"])

    assert {:ok, runner_pid} =
             Runic.Runner.start_link(
               name: runner,
               store: RunnerStore,
               store_opts: [store: store]
             )

    on_exit(fn ->
      try do
        if Process.alive?(runner_pid), do: Supervisor.stop(runner_pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert {:error, %Error{details: %{code: :workflow_public_contract_mismatch}}} =
             WorkflowTask.invoke(store, parent.id, "increment@1", %{n: "three"}, runner: runner)

    assert [^parent] = Queries.workflow_runs_for_session(store, "session:reuse")

    assert {:ok, result} =
             WorkflowTask.invoke(store, parent.id, resolved.reference, %{n: 3},
               runner: runner,
               child_run_id: "run:reuse-child",
               parent_node_id: "invoke_increment"
             )

    assert result.output == 4
    assert result.selection.decision == :reuse_exact
    assert result.child_run.status == "completed"
    assert result.child_run.definition_revision_id == created.revision.id
    assert result.child_run.compiled_artifact_id == artifact.id
    assert result.child_run.metadata_json["parent_run_id"] == parent.id
    assert result.child_run.metadata_json["parent_node_id"] == "invoke_increment"
    assert result.child_run.parent_run_id == parent.id
    assert result.child_run.parent_node_id == "invoke_increment"
    assert result.child_run.attempt == 1
    assert is_binary(result.child_run.invocation_key)

    assert {:ok, reused} =
             WorkflowTask.invoke(store, parent.id, resolved.reference, %{n: 3},
               runner: runner,
               child_run_id: "run:reuse-child",
               parent_node_id: "invoke_increment"
             )

    assert reused.output == 4
    assert reused.child_run.id == result.child_run.id
    assert reused.selection.decision == :reused_completed

    map_workflow =
      WorkflowTask.map_workflow(store, parent.id, resolved.reference,
        runner: runner,
        parent_node_id: "map_increment"
      )

    assert Enum.any?(map_workflow.graph.vertices, fn {_hash, vertex} ->
             match?(%Runic.Workflow.Map{}, vertex)
           end)

    map_results =
      map_workflow
      |> Workflow.react_until_satisfied([%{n: 1}, %{n: 4}], async: true, timeout: 5_000)
      |> Workflow.raw_productions()
      |> Enum.sort()

    assert map_results == [2, 5]

    repeated_map_results =
      store
      |> WorkflowTask.map_workflow(parent.id, resolved.reference,
        runner: runner,
        parent_node_id: "map_increment"
      )
      |> Workflow.react_until_satisfied([%{n: 1}, %{n: 4}], async: true, timeout: 5_000)
      |> Workflow.raw_productions()
      |> Enum.sort()

    assert repeated_map_results == [2, 5]

    child_runs =
      store
      |> Queries.workflow_runs_for_session("session:reuse")
      |> Enum.filter(&(&1.metadata_json["parent_run_id"] == parent.id))

    assert length(child_runs) == 3
    assert Enum.all?(child_runs, &(&1.status == "completed"))

    assert {:error, %Error{details: %{code: :workflow_reference_mismatch}}} =
             WorkflowLibrary.resolve(store, %{workflow_key: "increment", revision: 2})
  end
end
