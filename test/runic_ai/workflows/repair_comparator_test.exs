defmodule RunicAI.Workflows.RepairComparatorTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.TestClient
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.RepairComparator

  test "compares semantic and topology repairs through execution and measures collateral edits" do
    Enum.each([semantic_fixture(), topology_fixture()], fn fixture ->
      target_with_collateral =
        %{fixture.target_ir | policies: Map.put(fixture.target_ir.policies, "unrelated", true)}

      client = fn _model, prompt, _opts ->
        response =
          if String.contains?(prompt, "complete canonical workflow JSON") do
            Jason.encode!(target_with_collateral)
          else
            Jason.encode!(%{operations: fixture.operations})
          end

        {:ok, TestClient.result(response)}
      end

      assert {:ok, result} =
               RepairComparator.run_case(fixture,
                 author_client: client,
                 workspace_factory: &workspace/1
               )

      assert result.all_verified?
      assert result.typed_not_worse?

      whole = Enum.find(result.rows, &(&1.arm == :whole_object))
      typed = Enum.find(result.rows, &(&1.arm == :typed_operations))

      assert whole.status == :pass
      assert whole.metrics.verified_success
      refute whole.metrics.exact_semantic_repair
      assert whole.metrics.collateral_change_count > 0

      assert typed.status == :pass
      assert typed.metrics.verified_success
      assert typed.metrics.exact_semantic_repair
      assert typed.metrics.collateral_change_count == 0
      assert typed.metrics.distance_to_expected == 0
    end)
  end

  test "attributes malformed authoring output before validation or execution" do
    fixture = semantic_fixture()

    client = fn _model, prompt, _opts ->
      response =
        if String.contains?(prompt, "complete canonical workflow JSON"),
          do: "not json",
          else: Jason.encode!(%{operations: fixture.operations})

      {:ok, TestClient.result(response)}
    end

    assert {:ok, result} =
             RepairComparator.run_case(fixture,
               author_client: client,
               workspace_factory: &workspace/1
             )

    whole = Enum.find(result.rows, &(&1.arm == :whole_object))
    typed = Enum.find(result.rows, &(&1.arm == :typed_operations))

    assert whole.status == :fail
    assert whole.metrics.failure_layer == :json
    refute whole.metrics.verified_success
    assert typed.status == :pass
  end

  test "attributes a failed outcome check to proof rather than execution" do
    fixture = semantic_fixture()

    client = fn _model, prompt, _opts ->
      response =
        if String.contains?(prompt, "complete canonical workflow JSON"),
          do: Jason.encode!(fixture.target_ir),
          else: Jason.encode!(%{operations: fixture.operations})

      {:ok, TestClient.result(response)}
    end

    assert {:ok, result} =
             RepairComparator.run_case(fixture,
               author_client: client,
               workspace_factory: &workspace/1,
               verify_result: fn _result, _workspace -> false end
             )

    assert Enum.all?(result.rows, &(&1.status == :fail))
    assert Enum.all?(result.rows, &(&1.metrics.failure_layer == :proof))
    assert Enum.all?(result.rows, &(not &1.metrics.verified_success))
  end

  defp semantic_fixture do
    {base, _edge} = source_ir(%{"max_bytes" => 1}, true)
    operations = [%{op: "set_argument", node_id: "split", key: "max_bytes", value: 100}]
    {:ok, edit} = Editor.apply(base, %{base_revision: 1, operations: operations})

    %{
      id: "semantic-source-limit",
      task_family: "semantic_repair",
      instruction: "Set split.max_bytes to 100 and preserve everything else.",
      base_ir: base,
      target_ir: edit.ir,
      operations: operations
    }
  end

  defp topology_fixture do
    {connected, edge} = source_ir(%{"max_bytes" => 100}, true)
    base = %{connected | edges: %{}}
    operations = [%{op: "connect", edge: edge}]
    {:ok, edit} = Editor.apply(base, %{base_revision: 1, operations: operations})

    %{
      id: "topology-missing-edge",
      task_family: "topology_repair",
      instruction: "Connect split.out to materialize.in and preserve everything else.",
      base_ir: base,
      target_ir: edit.ir,
      operations: operations
    }
  end

  defp source_ir(split_arguments, connected?) do
    {:ok, split} =
      Node.new("split", :source_splitter,
        arguments: Map.merge(%{"paths" => ["input.txt"]}, split_arguments)
      )

    {:ok, materialize} = Node.new("materialize", :source_materializer)

    {:ok, edge} =
      Edge.new(%{node: "split", port: "out"}, %{node: "materialize", port: "in"})

    {:ok, ir} =
      IR.new("workflow:repair-comparator", "Materialize a bounded source",
        nodes: %{split.id => split, materialize.id => materialize},
        edges: if(connected?, do: %{edge.id => edge}, else: %{}),
        acceptance: [%{id: "source_materialized", required: true}],
        policies: %{"max_concurrency" => 1}
      )

    {ir, edge}
  end

  defp workspace(_arm) do
    root =
      Path.join(System.tmp_dir!(), "repair-comparator-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "input.txt"), "bounded source\n")
    Workspace.new!(root: root)
  end
end
