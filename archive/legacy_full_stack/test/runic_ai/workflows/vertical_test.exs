defmodule RunicAI.Workflows.VerticalTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.TestClient
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.Validator

  test "research workflow validates, lowers to native map/reduce, executes, and proves its artifact" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "notes"))

    File.write!(
      Path.join(root, "notes/incidents.md"),
      "# Incidents\n\nPayment retries caused duplicate work. Add idempotency and alerting.\n"
    )

    File.write!(
      Path.join(root, "notes/roadmap.md"),
      "# Roadmap\n\nThe retry redesign needs an owner and a delivery checkpoint.\n"
    )

    workspace = Workspace.new!(root: root)
    ir = research_ir()

    assert %{status: :accepted} = Validator.report(ir, mode: :runnable)
    assert {:ok, compiled} = Compiler.compile(ir, workspace)
    assert compiled.dialect == :component

    assert compiled.runic.component_specs
           |> Enum.find(&(&1.id == "extract"))
           |> Map.fetch!(:execution_shape) == :map

    assert compiled.runic.component_specs
           |> Enum.find(&(&1.id == "synthesize"))
           |> Map.fetch!(:execution_shape) == :reduce

    client = fn _model, prompt, _opts ->
      source =
        if to_string(prompt) =~ "duplicate", do: "notes/incidents.md", else: "notes/roadmap.md"

      {:ok,
       TestClient.result(
         "Delivery risk from #{source}: retry behavior needs a named owner and verification."
       )}
    end

    assert {:ok, result} = Compiler.run(ir, workspace, %{}, client: client, async: true)
    assert result.dialect == :component
    assert result.semantic_hash == IR.semantic_hash(ir)
    assert result.execution_metrics.lambda_map_calls > 0
    assert result.execution_metrics.lambda_reduce_calls >= 1
    assert [%{path: "reports/delivery-risk-report.md"}] = result.artifacts
    assert result.scorecard.objective_status == :objective_satisfied

    report = File.read!(Path.join(root, "reports/delivery-risk-report.md"))
    assert report =~ "Delivery Risk Report"
    assert report =~ "notes/"
  end

  test "bounded batch workflow parses records, fans out through native map, aggregates, and proves its artifact" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "data"))

    File.write!(
      Path.join(root, "data/work-items.csv"),
      "id,team,status\n1,api,ready\n2,web,blocked\n3,api,ready\n4,ops,review\n"
    )

    workspace = Workspace.new!(root: root)
    ir = batch_ir()

    assert %{status: :accepted} = Validator.report(ir, mode: :runnable)
    assert {:ok, compiled} = Compiler.compile(ir, workspace)

    assert compiled.runic.component_specs
           |> Enum.find(&(&1.id == "transform_each"))
           |> Map.fetch!(:execution_shape) == :map

    assert compiled.runic.component_specs
           |> Enum.find(&(&1.id == "aggregate"))
           |> Map.fetch!(:execution_shape) == :reduce

    assert {:ok, result} = Compiler.run(ir, workspace, %{}, async: true)
    assert result.execution_metrics.record_map_calls == 4
    assert result.execution_metrics.lambda_reduce_calls >= 1
    assert [%{path: "reports/batch-transformation-summary.md"}] = result.artifacts
    assert result.scorecard.objective_status == :objective_satisfied

    report = File.read!(Path.join(root, "reports/batch-transformation-summary.md"))
    assert report =~ "Batch Transformation Summary"
    assert report =~ "id=1 team=api status=ready"
    assert report =~ "id=2 team=web status=blocked"
    assert report =~ "id=4 team=ops status=review"
  end

  defp research_ir do
    nodes =
      [
        node("split", :lambda_split,
          paths: ["notes/incidents.md", "notes/roadmap.md"],
          max_bytes: 120
        ),
        node("materialize", :source_materializer),
        node("extract", :lambda_map,
          prompt: "Extract a delivery risk, mitigation, and source path from {{text}}"
        ),
        node("synthesize", :lambda_reduce, strategy: :join),
        node("compose", :lambda_generate,
          title: "Delivery Risk Report",
          sections: ["Delivery Risks", "Mitigations", "Sources"]
        ),
        node("write", :artifact_writer,
          path: "reports/delivery-risk-report.md",
          write_policy: :workspace_review
        ),
        node("verify", :objective_scorecard, artifact_path: "reports/delivery-risk-report.md")
      ]
      |> Map.new(&{&1.id, &1})

    edges =
      [
        edge(nodes, "split", "materialize"),
        edge(nodes, "materialize", "extract"),
        edge(nodes, "extract", "synthesize"),
        edge(nodes, "synthesize", "compose"),
        edge(nodes, "compose", "write"),
        edge(nodes, "write", "verify")
      ]
      |> Map.new(&{&1.id, &1})

    {:ok, ir} =
      IR.new("workflow:research-risk-report", "Produce a cited delivery risk report",
        inputs: %{
          "incidents" => %{kind: :source, path: "notes/incidents.md"},
          "roadmap" => %{kind: :source, path: "notes/roadmap.md"}
        },
        nodes: nodes,
        edges: edges,
        acceptance: [
          %{
            id: "report_written_and_scored",
            kind: :artifact_and_scorecard,
            required: true,
            description: "report artifact exists and objective scorecard is satisfied"
          }
        ],
        policies: %{write_policy: :workspace_review, max_concurrency: 2},
        presentation: %{layout: :left_to_right}
      )

    ir
  end

  defp batch_ir do
    nodes =
      [
        node("split", :source_splitter,
          paths: ["data/work-items.csv"],
          max_bytes: 16_000,
          max_chunks: 1
        ),
        node("materialize", :source_materializer),
        node("parse", :tabular_parser, format: :csv),
        node("transform_each", :record_map,
          max_items: 10,
          max_concurrency: 4,
          function: %{
            tier: :tier1,
            expr: %{
              op: "template",
              template: "id={{id}} team={{team}} status={{status}}",
              from: %{op: "input"}
            }
          }
        ),
        node("aggregate", :lambda_reduce, strategy: :join),
        node("compose", :lambda_generate,
          title: "Batch Transformation Summary",
          sections: ["Transformed Records"]
        ),
        node("write", :artifact_writer,
          path: "reports/batch-transformation-summary.md",
          write_policy: :workspace_review
        ),
        node("verify", :objective_scorecard,
          artifact_path: "reports/batch-transformation-summary.md",
          required_sections: ["Transformed Records"]
        )
      ]
      |> Map.new(&{&1.id, &1})

    edges =
      [
        edge(nodes, "split", "materialize"),
        edge(nodes, "materialize", "parse"),
        edge(nodes, "parse", "transform_each"),
        edge(nodes, "transform_each", "aggregate"),
        edge(nodes, "aggregate", "compose"),
        edge(nodes, "compose", "write"),
        edge(nodes, "write", "verify")
      ]
      |> Map.new(&{&1.id, &1})

    {:ok, ir} =
      IR.new(
        "workflow:bounded-batch-transformation",
        "Transform each bounded work item and aggregate a verified summary",
        inputs: %{"work_items" => %{kind: :source, path: "data/work-items.csv"}},
        nodes: nodes,
        edges: edges,
        acceptance: [
          %{
            id: "all_rows_transformed_and_summary_verified",
            kind: :artifact_and_scorecard,
            required: true,
            description: "all bounded records are mapped and the summary artifact is verified"
          }
        ],
        policies: %{write_policy: :workspace_review, max_concurrency: 4, max_items: 10},
        presentation: %{layout: :left_to_right}
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

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-workflow-vertical-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
