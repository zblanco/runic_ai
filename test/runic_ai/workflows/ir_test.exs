defmodule RunicAI.Workflows.IRTest do
  use ExUnit.Case, async: true

  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node

  test "IR V1 is id-keyed, JSON round-trippable, and presentation-independent" do
    {:ok, split} = Node.new("split", Catalog.component_key(:source_splitter))
    {:ok, materialize} = Node.new("materialize", Catalog.component_key(:source_materializer))

    {:ok, edge} =
      Edge.new(
        %{node: "split", port: "out"},
        %{node: "materialize", port: "in"}
      )

    {:ok, ir} =
      IR.new("workflow:test", "Materialize sources",
        nodes: %{split.id => split, materialize.id => materialize},
        edges: %{edge.id => edge},
        acceptance: [%{id: "materialized", required: true}],
        presentation: %{layout: "left_to_right"}
      )

    assert ir.format == "runic_ai/workflow_ir"
    assert ir.format_version == 1
    assert Map.keys(ir.nodes) |> Enum.sort() == ["materialize", "split"]
    assert edge.id == "split.out->materialize.in"

    hash = IR.semantic_hash(ir)
    decoded = ir |> Jason.encode!() |> Jason.decode!()

    assert {:ok, round_tripped} = IR.from_input(decoded)
    assert IR.semantic_hash(round_tripped) == hash
    assert IR.semantic_hash(%{ir | presentation: %{layout: "top_down"}}) == hash
  end

  test "node map keys must match stable node ids" do
    {:ok, node} = Node.new("actual", :source_discovery)

    assert {:error, error} =
             IR.new("workflow:mismatch", "Reject mismatch", nodes: %{"wrong" => node})

    assert error.details.code == :node_key_mismatch
  end

  test "catalog contracts are stable and version-pinned" do
    assert {:ok, first} = Catalog.resolve(:llm_map)
    assert {:ok, second} = Catalog.resolve("runic_ai/llm_map")

    assert first == second
    assert first.ref == "runic_ai/llm_map@2"
    assert byte_size(first.hash) == 64
    assert first.execution_shape == :map
    assert first.effects == [:model_call]
    assert first.replay.strategy == :at_least_once
    assert first.replay.automatic_retry?

    assert {:ok, writer} = Catalog.resolve(:artifact_writer)
    assert writer.replay.strategy == :reconcile
    assert writer.replay.idempotency_key == [:resolved_path, :content_sha256]

    assert {:ok, tool} = Catalog.resolve(:tool_leaf)
    refute tool.replay.automatic_retry?

    assert {:ok, edit} = Catalog.resolve("runic_ai/coding/edit")
    assert edit.replay.strategy == :reconcile_after_unknown
    assert edit.replay.reconciliation == :structured_patch_post_state
    assert edit.replay.requirement == :durable_unknown_after_dispatch_context
    refute edit.replay.automatic_retry?
  end
end
