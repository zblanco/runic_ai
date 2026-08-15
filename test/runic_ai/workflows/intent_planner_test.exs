defmodule RunicAI.Workflows.IntentPlannerTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.TestClient
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IntentPlanner

  setup do
    root =
      Path.join(System.tmp_dir!(), "intent-planner-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "input.txt"), "A bounded source for the generated workflow.\n")
    {:ok, store} = SQLite.open(":memory:")

    on_exit(fn ->
      SQLite.close(store)
      File.rm_rf!(root)
    end)

    %{store: store, workspace: Workspace.new!(root: root)}
  end

  test "drafts intent into canonical IR, compiles, persists provenance, executes, and becomes reusable",
       %{store: store, workspace: workspace} do
    objective = "Materialize repository sources"

    assert {:ok, planned} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: objective, input_paths: ["input.txt"]},
               strategy: :workflow,
               workflow_key: "materialize-repository-sources",
               blueprint: blueprint(objective)
             )

    assert planned.status == :drafted
    assert planned.strategy == :draft
    assert planned.route.strategy == :draft
    assert planned.ir.metadata.planning.strategy == :draft
    assert planned.definition.revision.semantic_hash == IR.semantic_hash(planned.ir)
    assert planned.definition.revision.catalog_hash == planned.artifact.catalog_hash
    assert planned.compiled.compiled_hash == planned.artifact.compiled_hash
    assert planned.projection.projection_kind == "json"

    assert get_in(planned.definition.revision.metadata_json, ["planning", "strategy"]) ==
             "draft"

    assert get_in(planned.definition.revision.metadata_json, [
             "public_contract",
             "inputs",
             "properties",
             "input_paths",
             "const"
           ]) == ["input.txt"]

    assert {:ok, execution} = Compiler.run(planned.ir, workspace)
    assert execution.output != nil
    assert execution.semantic_hash == planned.definition.revision.semantic_hash

    assert {:ok, _review} =
             WorkflowDefinitions.request_review(store, planned.definition.workflow.id)

    assert {:ok, _approval} =
             WorkflowDefinitions.approve(store, planned.definition.workflow.id)

    assert {:ok, _activation} =
             WorkflowDefinitions.activate(store, planned.definition.workflow.id)

    assert {:ok, reused} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: objective, input_paths: ["input.txt"]},
               strategy: :workflow
             )

    assert reused.status == :ready
    assert reused.strategy == :reuse_exact
    assert reused.reference.workflow_key == "materialize-repository-sources"
    assert reused.reference.definition_hash == planned.definition.revision.semantic_hash
  end

  test "pins the selected model only on model-calling nodes in the durable revision",
       %{store: store, workspace: workspace} do
    objective = "Analyze repository sources"

    assert {:ok, planned} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: objective, input_paths: ["input.txt"]},
               strategy: :workflow,
               model: "openai:gpt-5.6-luna",
               workflow_key: "analyze-repository-sources",
               blueprint: model_blueprint(objective)
             )

    assert planned.ir.nodes["map"].arguments.model == "openai:gpt-5.6-luna"
    refute Map.has_key?(planned.ir.nodes["materialize"].arguments, :model)

    assert get_in(planned.definition.revision.ir_json, [
             "nodes",
             "map",
             "arguments",
             "model"
           ]) == "openai:gpt-5.6-luna"

    compiled_map = Enum.find(planned.compiled.blueprint.components, &(&1.id == "map"))
    assert compiled_map.params.model == "openai:gpt-5.6-luna"
    assert :model_call in planned.ir.nodes["map"].effects
    assert planned.ir.nodes["score"].effects == []
    assert planned.ir.nodes["report"].effects == []
  end

  test "drafts a coding proposal through the shared intent and revision boundary",
       %{store: store, workspace: workspace} do
    objective = "Analyze repository files and summarize the implementation"

    proposal = %{
      id: "workflow:coding-repository-analysis",
      objective: objective,
      nodes: [
        %{id: "discover", kind: "tool", params: %{tool: "find_files"}},
        %{id: "answer", kind: "reducer", params: %{reducer: "report"}}
      ],
      edges: [%{from: "discover", to: "answer"}],
      stop_conditions: ["repository analysis returned"]
    }

    validation_opts = [allowed_tools: ["find_files"]]

    assert {:ok, planned} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: objective, input_paths: ["input.txt"]},
               strategy: :workflow,
               dialect: :coding,
               workflow_key: "coding-repository-analysis",
               coding_proposal: proposal,
               coding_opts: [validation_opts: validation_opts],
               compile_opts: [validation_opts: validation_opts]
             )

    assert planned.status == :drafted
    assert planned.strategy == :draft
    assert planned.compiled.dialect == :coding
    assert planned.proposal.id == "workflow:coding-repository-analysis"
    assert planned.ir.nodes["discover"].kind == :coding

    assert get_in(planned.definition.revision.metadata_json, ["adapter", "source"]) ==
             "coding_workflow_proposal"

    assert planned.definition.revision.semantic_hash == IR.semantic_hash(planned.ir)
    assert planned.artifact.compiled_hash == planned.compiled.compiled_hash
  end

  test "adapts a compatible proven revision through typed operations into a new draft",
       %{store: store, workspace: workspace} do
    assert {:ok, base} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: "Analyze repository sources", input_paths: ["input.txt"]},
               strategy: :workflow,
               workflow_key: "analyze-repository-sources-base",
               blueprint: model_blueprint("Analyze repository sources")
             )

    assert {:ok, _review} =
             WorkflowDefinitions.request_review(store, base.definition.workflow.id)

    assert {:ok, _approval} =
             WorkflowDefinitions.approve(store, base.definition.workflow.id)

    assert {:ok, _activation} =
             WorkflowDefinitions.activate(store, base.definition.workflow.id)

    assert {:ok, adapted} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: "Analyze repository risks", input_paths: ["input.txt"]},
               strategy: :workflow,
               workflow_key: "analyze-repository-risks-adapted",
               model: "openai:gpt-5.6-luna",
               adapt_operations: [
                 %{op: "set_policy", key: "max_runtime_ms", value: 120_000}
               ]
             )

    assert adapted.status == :drafted
    assert adapted.strategy == :adapt
    refute adapted.route.selected.compatible?
    assert adapted.route.selected.adaptable?
    assert adapted.base_reference.workflow_key == "analyze-repository-sources-base"
    assert adapted.definition.workflow.workflow_key == "analyze-repository-risks-adapted"
    assert adapted.ir.objective == "Analyze repository risks"
    assert adapted.ir.policies["max_runtime_ms"] == 120_000
    assert adapted.adaptation_authoring.source == "provided"

    assert get_in(adapted.definition.revision.metadata_json, [
             "planning",
             "selected_base",
             "workflow_key"
           ]) == "analyze-repository-sources-base"

    assert get_in(adapted.definition.revision.metadata_json, [
             "adaptation",
             "protocol"
           ]) == "typed_operations_v1"

    assert WorkflowDefinitions.get(store, "analyze-repository-sources-base").status == "active"
    assert WorkflowDefinitions.get(store, "analyze-repository-risks-adapted").status == "pending"
  end

  test "repairs one malformed model-authored adaptation transaction before applying it",
       %{store: store, workspace: workspace} do
    assert {:ok, base} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: "Analyze repository sources", input_paths: ["input.txt"]},
               strategy: :workflow,
               workflow_key: "repairable-adaptation-base",
               blueprint: model_blueprint("Analyze repository sources")
             )

    assert {:ok, _review} =
             WorkflowDefinitions.request_review(store, base.definition.workflow.id)

    assert {:ok, _approval} = WorkflowDefinitions.approve(store, base.definition.workflow.id)
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, base.definition.workflow.id)

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    client = fn _model, _prompt, _opts ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      response =
        if call == 0 do
          ~s({"operations":[{"op":"set_acceptance","acceptance_id":"done","check":"invalid"}]})
        else
          ~s({"operations":[{"op":"set_policy","key":"max_runtime_ms","value":90000}]})
        end

      {:ok, TestClient.result(response)}
    end

    assert {:ok, adapted} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: "Analyze repository risks", input_paths: ["input.txt"]},
               strategy: :workflow,
               workflow_key: "repairable-adaptation-result",
               model: "test:model",
               client: client
             )

    assert Agent.get(calls, & &1) == 2
    assert adapted.strategy == :adapt
    assert adapted.ir.policies["max_runtime_ms"] == 90_000
    assert adapted.adaptation_authoring.source == "model"
    assert adapted.adaptation_authoring.repair.attempted

    assert adapted.adaptation_operations == [
             %{"op" => "set_policy", "key" => "max_runtime_ms", "value" => 90_000}
           ]
  end

  test "repairs one malformed adaptation JSON response before decoding it",
       %{store: store, workspace: workspace} do
    assert {:ok, base} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: "Analyze repository sources", input_paths: ["input.txt"]},
               strategy: :workflow,
               workflow_key: "decode-repair-adaptation-base",
               blueprint: model_blueprint("Analyze repository sources")
             )

    assert {:ok, _review} =
             WorkflowDefinitions.request_review(store, base.definition.workflow.id)

    assert {:ok, _approval} = WorkflowDefinitions.approve(store, base.definition.workflow.id)
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, base.definition.workflow.id)

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    client = fn _model, _prompt, _opts ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      response =
        if call == 0 do
          ~s({"operations":[{"op":"set_policy","key":"max_runtime_ms","value":})
        else
          ~s({"operations":[{"op":"set_policy","key":"max_runtime_ms","value":60000}]})
        end

      {:ok, TestClient.result(response)}
    end

    assert {:ok, adapted} =
             IntentPlanner.plan(
               store,
               workspace,
               %{objective: "Analyze repository risks", input_paths: ["input.txt"]},
               strategy: :workflow,
               workflow_key: "decode-repair-adaptation-result",
               model: "test:model",
               client: client
             )

    assert Agent.get(calls, & &1) == 2
    assert adapted.ir.policies["max_runtime_ms"] == 60_000
    assert adapted.adaptation_authoring.repair.stage == "decode"
  end

  defp blueprint(objective) do
    %{
      id: "workflow:materialize-repository-sources",
      objective: objective,
      sources: [%{id: "input", path: "input.txt"}],
      components: [
        %{
          id: "split",
          type: "source_splitter",
          params: %{paths: ["input.txt"], max_bytes: 1_000}
        },
        %{id: "materialize", type: "source_materializer", params: %{}}
      ],
      edges: [
        %{from: "split", output: "out", to: "materialize", input: "in"}
      ],
      stop_conditions: ["sources materialized"],
      policies: %{max_concurrency: 1},
      metadata: %{proposal_kind: "fixture"}
    }
  end

  defp model_blueprint(objective) do
    %{
      id: "workflow:analyze-repository-sources",
      objective: objective,
      sources: [%{id: "input", path: "input.txt"}],
      components: [
        %{
          id: "split",
          type: "source_splitter",
          params: %{paths: ["input.txt"], max_bytes: 1_000}
        },
        %{id: "materialize", type: "source_materializer", params: %{}},
        %{id: "map", type: "llm_map", params: %{prompt: "Analyze {{content}}"}},
        %{id: "report", type: "lambda_generate", params: %{}},
        %{id: "score", type: "lambda_review", params: %{required_sections: []}}
      ],
      edges: [
        %{from: "split", output: "out", to: "materialize", input: "in"},
        %{from: "materialize", output: "out", to: "map", input: "in"}
      ],
      stop_conditions: ["sources analyzed"],
      policies: %{max_concurrency: 1},
      metadata: %{proposal_kind: "fixture"}
    }
  end
end
