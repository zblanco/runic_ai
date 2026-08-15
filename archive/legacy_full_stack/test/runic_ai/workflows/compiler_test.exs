defmodule RunicAI.Workflows.CompilerTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node

  test "general component IR lowers through the native Runic compiler with source mapping" do
    workspace = Workspace.new!(root: File.cwd!())
    ir = source_workflow()

    assert {:ok, compiled} = Compiler.compile(ir, workspace)
    assert compiled.semantic_hash == IR.semantic_hash(ir)
    assert byte_size(compiled.compiled_hash) == 64

    assert compiled.source_map == %{
             "materialize" => %{runic_nodes: ["assistant_node_2_materialize"]},
             "split" => %{runic_nodes: ["assistant_node_1_split"]}
           }

    assert compiled.runic.graph_summary.nodes |> length() >= 2
    assert compiled.blueprint.metadata.workflow_ir_version == 1
  end

  test "coding dialect lowers through the explicit typed domain adapter" do
    root = tmp_dir()

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Fixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :fixture, version: \"0.1.0\"]\nend\n"
    )

    workspace = Workspace.new!(root: root)

    {:ok, command} =
      Node.new("compile", "runic_ai/coding/command",
        kind: :coding,
        arguments: %{args: %{argv: ["mix", "compile", "--warnings-as-errors"]}}
      )

    {:ok, verify} =
      Node.new("verify", "runic_ai/coding/verification_gate",
        kind: :coding,
        arguments: %{
          checks: [
            %{
              type: "command_passes",
              params: %{argv: ["mix", "compile", "--warnings-as-errors"]}
            }
          ]
        }
      )

    {:ok, edge} =
      Edge.new(%{node: "compile", port: "context"}, %{node: "verify", port: "context"})

    {:ok, ir} =
      IR.new("workflow:coding", "Compile a repository",
        nodes: %{command.id => command, verify.id => verify},
        edges: %{edge.id => edge},
        acceptance: [
          %{
            id: "stop_1",
            kind: :declared_stop_condition,
            condition: "compile passes",
            required: true
          }
        ]
      )

    assert {:ok, compiled} =
             Compiler.compile(ir, workspace, validation_opts: [allow_commands?: true])

    assert compiled.dialect == :coding
    assert compiled.proposal.id == ir.id
    assert compiled.source_map["compile"].runic_nodes == ["rlm_node_1_compile"]
    assert compiled.domain_validation_report.status == :accepted

    assert {:ok, result} =
             Compiler.run(ir, workspace, %{}, validation_opts: [allow_commands?: true])

    assert result.dialect == :coding
    assert Enum.any?(result.context.command_results, &(&1.exit_status == 0))
    assert Enum.any?(result.context.scorecards, &(&1.objective_status == :objective_satisfied))
  end

  test "mixed component and coding dialects fail explicitly" do
    workspace = Workspace.new!(root: File.cwd!())
    {:ok, component} = Node.new("discover", :source_discovery)
    {:ok, coding} = Node.new("agent", "runic_ai/coding/agent", kind: :coding)

    {:ok, ir} =
      IR.new("workflow:mixed", "Reject an undefined dialect bridge",
        nodes: %{component.id => component, coding.id => coding},
        acceptance: [%{id: "verified", required: true}]
      )

    assert {:error, error} = Compiler.compile(ir, workspace)
    assert error.details.code == :unsupported_workflow_dialect
    assert error.details.dialects == [:coding, :component]
  end

  test "compiled hash excludes VM-local Runic presentation hashes" do
    stable_summary = %{
      id: "workflow:stable",
      nodes: [%{id: "node", name: "node"}],
      roots: ["node"],
      edges: [],
      objective: "Stable lowering",
      stop_conditions: ["done"],
      batches: [["node"]],
      leaves: ["node"],
      runic: %{
        native_nodes: [%{id: "node", name: "node", kind: :component}],
        required_context_keys: %{"node" => [%{key: :component, required?: true}]},
        build_log_count: 1,
        scheduler_policy_count: 1,
        edgelist: [%{from: "123", to: "456"}],
        serializers: %{mermaid: "n123 --> n456"}
      }
    }

    changed_vm_hashes =
      put_in(stable_summary, [:runic, :edgelist], [%{from: "987", to: "654"}])
      |> put_in([:runic, :serializers], %{mermaid: "n987 --> n654"})

    runic = %{
      graph_summary: stable_summary,
      component_specs: [%{id: "node", type: :source_discovery}],
      node_names: %{"node" => "assistant_node_1_node"}
    }

    changed = %{runic | graph_summary: changed_vm_hashes}
    source_map = %{"node" => %{runic_nodes: ["assistant_node_1_node"]}}

    assert Compiler.compiled_hash("semantic", :component, runic, source_map) ==
             Compiler.compiled_hash("semantic", :component, changed, source_map)
  end

  test "compiled hash survives the canonical JSON persistence boundary" do
    workspace = Workspace.new!(root: File.cwd!())

    {:ok, transform} =
      Node.new("transform_each", :record_map,
        arguments: %{
          max_concurrency: 4,
          function: %{
            tier: :tier1,
            expr: %{
              op: "template",
              template: "id={{id}} status={{status}}",
              from: %{op: "input"}
            }
          }
        }
      )

    {:ok, ir} =
      IR.new("workflow:json-stable-lowering", "Transform bounded records",
        nodes: %{transform.id => transform},
        acceptance: [%{id: "records_transformed", required: true}]
      )

    persisted = ir |> Jason.encode!() |> Jason.decode!()

    assert {:ok, authored} = Compiler.compile(ir, workspace)
    assert {:ok, restored} = Compiler.compile(persisted, workspace)
    assert restored.semantic_hash == authored.semantic_hash
    assert restored.compiled_hash == authored.compiled_hash
  end

  defp source_workflow do
    {:ok, split} = Node.new("split", :source_splitter)
    {:ok, materialize} = Node.new("materialize", :source_materializer)

    {:ok, edge} =
      Edge.new(
        %{node: split.id, port: "out"},
        %{node: materialize.id, port: "in"}
      )

    {:ok, ir} =
      IR.new("workflow:source", "Materialize sources",
        nodes: %{split.id => split, materialize.id => materialize},
        edges: %{edge.id => edge},
        acceptance: [%{id: "sources_materialized", required: true}]
      )

    ir
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-workflow-compiler-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
