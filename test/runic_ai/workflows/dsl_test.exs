defmodule RunicAI.Workflows.DSLTest do
  use ExUnit.Case, async: true

  alias RunicAI.Workflows.DSL
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node

  test "compact DSL round trips canonical semantics and rejects stale contract pins" do
    {:ok, discover} = Node.new("discover", :source_discovery, arguments: %{paths: ["notes/"]})
    {:ok, split} = Node.new("split", :source_splitter, arguments: %{max_bytes: 1_000})

    {:ok, edge} =
      Edge.new(%{node: discover.id, port: "out"}, %{node: split.id, port: "in"})

    {:ok, ir} =
      IR.new("workflow:dsl", "Discover and split source material",
        nodes: %{discover.id => discover, split.id => split},
        edges: %{edge.id => edge},
        acceptance: [%{id: "sources_split", required: true}],
        policies: %{max_runtime_ms: 5_000},
        presentation: %{layout: "left_to_right"}
      )

    assert {:ok, source} = DSL.render(ir)
    assert source =~ "runic-workflow\t1"
    assert source =~ "node\t\"discover\""
    assert source =~ "edge\t\"discover.out->split.in\""

    assert {:ok, parsed} = DSL.parse(source)
    assert IR.semantic_hash(parsed) == IR.semantic_hash(ir)

    canonical_json_bytes = ir |> Jason.encode!() |> byte_size()
    assert byte_size(source) < canonical_json_bytes

    stale = String.replace(source, discover.contract.hash, String.duplicate("0", 64))

    assert {:error, error} = DSL.parse(stale)
    assert error.details.code == :stale_component_contract
    assert error.details.node_id == "discover"
  end

  test "DSL reports exact line numbers for malformed fragments" do
    source = """
    runic-workflow\t1
    id\t"workflow:bad"
    objective\t"Bad fragment"
    policies\t{bad}
    end
    """

    assert {:error, error} = DSL.parse(source)
    assert error.details.code == :invalid_json_fragment
    assert error.details.line == 4
  end
end
