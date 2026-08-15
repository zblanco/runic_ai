defmodule RunicAI.Workflows.EditorTest do
  use ExUnit.Case, async: true

  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node

  test "applies a typed operation batch atomically with revision, diff, and inverse operations" do
    ir = base_ir(holes: [%{id: "review", need: "choose review policy"}])

    batch = %{
      base_revision: 1,
      base_hash: IR.semantic_hash(ir),
      operations: [
        %{op: "set_argument", node_id: "split", key: "max_chunks", value: 4},
        %{op: "set_policy", node_id: "split", key: "max_concurrency", value: 2},
        %{
          op: "set_acceptance",
          acceptance_id: "bounded",
          check: %{description: "no more than four chunks", required: true}
        },
        %{op: "resolve_hole", hole_id: "review"},
        %{op: "annotate", node_id: "split", key: "rationale", value: "bounded fan-out"}
      ]
    }

    assert {:ok, result} = Editor.apply(ir, batch)
    assert result.base_revision == 1
    assert result.result_revision == 2
    assert result.ir.nodes["split"].arguments["max_chunks"] == 4
    assert result.ir.nodes["split"].policy["max_concurrency"] == 2
    assert result.ir.nodes["split"].metadata["rationale"] == "bounded fan-out"
    assert result.ir.holes == []
    assert Enum.any?(result.ir.acceptance, &((&1[:id] || &1["id"]) == "bounded"))
    assert result.affected_nodes == ["split"]
    assert result.diff.nodes.changed == ["split"]
    assert length(result.inverse_operations) == 5

    assert {:ok, undone} =
             Editor.apply(result.ir, %{
               base_revision: result.result_revision,
               operations: result.inverse_operations
             })

    assert semantic_fields(undone.ir) == semantic_fields(ir)
  end

  test "rejects stale base revisions without returning a partial workflow" do
    ir = base_ir()

    assert {:error, error} =
             Editor.apply(ir, %{
               base_revision: 0,
               operations: [%{op: "set_policy", key: "budget", value: 2}]
             })

    assert error.details.code == :stale_revision
    assert ir.policies == %{}
    assert ir.revision == 1
  end

  test "rejects a partial replacement that erases acceptance lowering semantics" do
    ir =
      base_ir()
      |> Map.put(:acceptance, [
        %{
          id: "done",
          kind: "declared_stop_condition",
          condition: "old artifact exists",
          required: true
        }
      ])

    assert {:error, error} =
             Editor.apply(ir, %{
               base_revision: ir.revision,
               operations: [
                 %{
                   op: "set_acceptance",
                   acceptance_id: "done",
                   check: %{id: "done", description: "new artifact exists", required: true}
                 }
               ]
             })

    assert error.details.code == :incomplete_acceptance_replacement
    assert ir.acceptance |> hd() |> Map.fetch!(:condition) == "old artifact exists"
  end

  test "rejects an incompatible connection at transaction time with node and port diagnostics" do
    {:ok, discover} = Node.new("discover", :source_discovery)
    {:ok, materialize} = Node.new("materialize", :source_materializer)

    {:ok, ir} =
      IR.new("workflow:incompatible-edit", "Reject an incompatible edit",
        nodes: %{discover.id => discover, materialize.id => materialize},
        acceptance: [%{id: "done", required: true}]
      )

    assert {:error, error} =
             Editor.apply(ir, %{
               base_revision: 1,
               operations: [
                 %{
                   op: "connect",
                   from: %{node: "discover", port: "out"},
                   to: %{node: "materialize", port: "in"}
                 }
               ]
             })

    assert error.details.code == :operation_batch_rejected

    assert Enum.any?(error.details.report.diagnostics, fn diagnostic ->
             diagnostic.code == :incompatible_port_contract and
               diagnostic.details.from.node == "discover" and
               diagnostic.details.to.node == "materialize"
           end)

    assert ir.edges == %{}
  end

  test "connected node removal requires an explicit cascade and returns a restorable inverse" do
    ir = base_ir()

    assert {:error, error} =
             Editor.apply(ir, %{
               base_revision: 1,
               operations: [%{op: "remove_node", node_id: "split", cascade: false}]
             })

    assert error.details.code == :cascade_required

    assert {:ok, removed} =
             Editor.apply(ir, %{
               base_revision: 1,
               operations: [%{op: "remove_node", node_id: "split", cascade: true}]
             })

    assert removed.ir.nodes == %{"materialize" => ir.nodes["materialize"]}
    assert removed.ir.edges == %{}

    assert [add_node, connect] = removed.inverse_operations
    assert add_node.op == "add_node"
    assert connect.op == "connect"
  end

  test "string operation keys replace equivalent atom keys without creating ambiguous JSON" do
    ir = base_ir()
    split = put_in(ir.nodes["split"].arguments, %{max_chunks: 2})

    assert {:ok, result} =
             Editor.apply(split, %{
               base_revision: split.revision,
               operations: [
                 %{op: "set_argument", node_id: "split", key: "max_chunks", value: 4}
               ]
             })

    assert result.ir.nodes["split"].arguments == %{max_chunks: 4}
  end

  test "rejects map keys that collide after JSON encoding" do
    assert {:error, error} =
             Node.new("ambiguous", :blueprint_transform,
               arguments: %{"operation" => "second", operation: "first"}
             )

    assert error.details.code == :ambiguous_json_key
    assert error.details.canonical_key == "operation"
  end

  defp base_ir(opts \\ []) do
    {:ok, split} = Node.new("split", :source_splitter)
    {:ok, materialize} = Node.new("materialize", :source_materializer)

    {:ok, edge} =
      Edge.new(%{node: "split", port: "out"}, %{node: "materialize", port: "in"})

    {:ok, ir} =
      IR.new("workflow:editable", "Edit a workflow",
        nodes: %{split.id => split, materialize.id => materialize},
        edges: %{edge.id => edge},
        acceptance: [%{id: "done", required: true}],
        holes: Keyword.get(opts, :holes, [])
      )

    ir
  end

  defp semantic_fields(ir) do
    ir
    |> Map.from_struct()
    |> Map.drop([:revision])
  end
end
