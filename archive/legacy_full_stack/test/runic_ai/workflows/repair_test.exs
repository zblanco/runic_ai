defmodule RunicAI.Workflows.RepairTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.TestClient
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.Repair
  alias RunicAI.Workflows.Validator

  test "repairs post-adapter contract and topology failures through typed operations" do
    ir = invalid_research_ir()
    assert Validator.report(ir, mode: :runnable).status == :rejected

    client = fn _model, _prompt, _opts ->
      operations = [
        %{
          op: "replace_node",
          node_id: "join_notes",
          node: %{
            id: "join_notes",
            component: "runic_ai/lambda_reduce",
            arguments: %{strategy: "join"}
          }
        },
        %{
          op: "replace_node",
          node_id: "synthesize",
          node: %{
            id: "synthesize",
            component: "runic_ai/lambda_generate",
            arguments: %{title: "Source Report", sections: ["Summary"]}
          }
        },
        %{op: "remove_node", node_id: "review", cascade: true},
        %{
          op: "connect",
          from: %{node: "synthesize", port: "out"},
          to: %{node: "write", port: "in"}
        }
      ]

      {:ok, TestClient.result(Jason.encode!(%{operations: operations}))}
    end

    workspace = Workspace.new!(root: File.cwd!())

    assert {:ok, repaired} =
             Repair.to_runnable(ir, workspace,
               model: "test:model",
               client: client,
               workflow_repair_attempts: 1
             )

    assert repaired.compiled.validation_report.status == :accepted
    assert [%{status: :applied, operations: operations}] = repaired.history
    assert length(operations) == 4
    assert repaired.ir.nodes["join_notes"].component == "runic_ai/lambda_reduce"
    assert repaired.ir.nodes["synthesize"].component == "runic_ai/lambda_generate"
    refute Map.has_key?(repaired.ir.nodes, "review")

    assert Enum.any?(repaired.ir.edges, fn {_id, edge} ->
             edge.from.node == "synthesize" and edge.to.node == "write"
           end)
  end

  defp invalid_research_ir do
    nodes =
      [
        node("split", :source_splitter, paths: ["input.txt"]),
        node("materialize", :source_materializer),
        node("extract", :llm_map, prompt: "Extract notes from {{text}}"),
        node("join_notes", :blueprint_reduce, strategy: "join"),
        node("synthesize", :llm_leaf, prompt: "Synthesize {{items}}"),
        node("review", :lambda_review),
        node("write", :artifact_writer, path: ".docs/report.md"),
        node("score", :objective_scorecard, artifact_path: ".docs/report.md")
      ]
      |> Map.new(&{&1.id, &1})

    edges =
      [
        edge(nodes, "split", "materialize"),
        edge(nodes, "materialize", "extract"),
        edge(nodes, "extract", "join_notes"),
        edge(nodes, "join_notes", "synthesize"),
        edge(nodes, "synthesize", "review"),
        edge(nodes, "review", "write"),
        edge(nodes, "write", "score")
      ]
      |> Map.new(&{&1.id, &1})

    {:ok, ir} =
      IR.new("workflow:repair-after-adapter", "Write a source report",
        nodes: nodes,
        edges: edges,
        acceptance: [%{id: "report_written", required: true}]
      )

    ir
  end

  defp node(id, type, arguments \\ []) do
    {:ok, node} = Node.new(id, type, arguments: Map.new(arguments))
    node
  end

  defp edge(nodes, from, to) do
    [from_port] = Map.keys(nodes[from].contract.outputs)
    [to_port] = Map.keys(nodes[to].contract.inputs)
    {:ok, edge} = Edge.new(%{node: from, port: from_port}, %{node: to, port: to_port})
    edge
  end
end
