defmodule RunicAI.Workflows.AdapterTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Workflows.Adapters.AssistantBlueprint
  alias RunicAI.Workflows.Adapters.CodingProposal

  test "assistant adapter replaces legacy declared ports with authoritative exact catalog ports" do
    split =
      ComponentBlueprint.new!("split", :source_splitter, outputs: ["legacy_output"])

    materialize =
      ComponentBlueprint.new!("materialize", :source_materializer, inputs: ["legacy_input"])

    blueprint =
      WorkflowBlueprint.new!("Materialize sources", [split, materialize],
        edges: [%{from: "split", to: "materialize"}],
        stop_conditions: ["sources materialized"]
      )

    assert {:ok, result} = AssistantBlueprint.adapt(blueprint)
    refute result.lossless?

    assert result.ir.nodes["split"].contract.outputs |> Map.keys() == ["out"]
    assert result.ir.nodes["materialize"].contract.inputs |> Map.keys() == ["in"]
    assert %{"split.out->materialize.in" => edge} = result.ir.edges
    assert edge.from == %{node: "split", port: "out"}
    assert edge.to == %{node: "materialize", port: "in"}

    assert Enum.any?(result.diagnostics, &(&1.code == :ignored_blueprint_ports))
    assert Enum.any?(result.diagnostics, &(&1.code == :inferred_legacy_port))
  end

  test "assistant adapter rejects an explicit port that is absent from the catalog contract" do
    input = %{
      objective: "Materialize sources",
      components: [
        %{id: "split", type: "source_splitter", params: %{}},
        %{id: "materialize", type: "source_materializer", params: %{}}
      ],
      edges: [
        %{from: "split", output: "missing", to: "materialize", input: "in"}
      ],
      stop_conditions: ["sources materialized"]
    }

    assert {:error, error} = AssistantBlueprint.adapt(input)
    assert error.details.code == :unknown_edge_port
    assert error.details.side == :from
  end

  test "coding proposals enter the shared IR as an explicit versioned domain dialect" do
    inspect_node =
      ProposalNode.new!("inspect", :agent,
        params: %{mode: "verify", task: "Inspect the repository"}
      )

    verify_node =
      ProposalNode.new!("verify", :verification_gate,
        params: %{checks: [%{type: "command_passes", argv: ["mix", "test"]}]}
      )

    proposal =
      WorkflowProposal.new!("Inspect and verify", [inspect_node, verify_node],
        edges: [%{from: "inspect", to: "verify"}],
        stop_conditions: ["verification passes"]
      )

    assert {:ok, result} = CodingProposal.adapt(proposal)
    refute result.lossless?

    assert result.ir.nodes["inspect"].component == "runic_ai/coding/agent"
    assert result.ir.nodes["verify"].contract.execution_shape == :acceptance
    assert Map.has_key?(result.ir.edges, "inspect.context->verify.context")
    assert Enum.any?(result.diagnostics, &(&1.code == :domain_lowering_required))
  end
end
