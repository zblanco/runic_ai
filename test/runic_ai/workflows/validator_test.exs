defmodule RunicAI.Workflows.ValidatorTest do
  use ExUnit.Case, async: true

  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.Validator

  test "compatible exact ports produce a runnable workflow" do
    ir = workflow(:source_splitter, :source_materializer)

    assert %{status: :accepted, mode: :runnable, diagnostics: diagnostics} =
             Validator.report(ir, mode: :runnable)

    refute Enum.any?(diagnostics, &(&1.severity == :error))
  end

  test "typed Lambda reduction may feed terminal model synthesis" do
    ir = workflow(:lambda_reduce, :llm_leaf)

    assert %{status: :accepted, mode: :runnable, diagnostics: diagnostics} =
             Validator.report(ir, mode: :runnable)

    refute Enum.any?(diagnostics, &(&1.severity == :error))
  end

  test "incompatible exact ports fail before compilation" do
    ir = workflow(:source_discovery, :source_materializer)

    assert %{status: :rejected, diagnostics: diagnostics} =
             Validator.report(ir, mode: :draft)

    assert Enum.any?(diagnostics, &(&1.code == :incompatible_port_contract))
  end

  test "producer unions use safe assignability instead of accepting one overlapping option" do
    ir = workflow(:source_discovery, :source_splitter)

    # source_discovery produces only source_set, which is accepted by the
    # source_splitter's source_set | source_request input.
    assert Validator.report(ir, mode: :runnable).status == :accepted

    ir = workflow(:artifact_materializer, :source_splitter)

    assert %{status: :rejected, diagnostics: diagnostics} =
             Validator.report(ir, mode: :runnable)

    assert Enum.any?(diagnostics, &(&1.code == :incompatible_port_contract))
  end

  test "holes and missing acceptance are progressive in draft mode and blocking in runnable mode" do
    {:ok, node} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:draft", "Draft a workflow",
        nodes: %{node.id => node},
        holes: [%{id: "verifier", need: "choose a verifier"}]
      )

    assert %{status: :accepted, diagnostics: draft_diagnostics} =
             Validator.report(ir, mode: :draft)

    assert Enum.any?(draft_diagnostics, &(&1.code == :unresolved_holes))
    assert Enum.any?(draft_diagnostics, &(&1.code == :missing_acceptance))

    assert %{status: :rejected, diagnostics: runnable_diagnostics} =
             Validator.report(ir, mode: :runnable)

    assert Enum.count(runnable_diagnostics, &(&1.severity == :error)) == 2
  end

  test "critical any boundaries are visible in drafts and rejected when runnable" do
    ir = workflow(:sandbox_execute, :tool_leaf)

    assert %{status: :accepted, diagnostics: draft_diagnostics} =
             Validator.report(ir, mode: :draft)

    assert Enum.any?(draft_diagnostics, fn diagnostic ->
             diagnostic.code == :untyped_port_boundary and diagnostic.severity == :warning
           end)

    assert %{status: :rejected, diagnostics: runnable_diagnostics} =
             Validator.report(ir, mode: :runnable)

    assert Enum.any?(runnable_diagnostics, fn diagnostic ->
             diagnostic.code == :untyped_port_boundary and diagnostic.severity == :error
           end)
  end

  test "stale catalog pins require revalidation before a workflow is runnable" do
    ir = workflow(:source_splitter, :source_materializer)
    split = ir.nodes["source"]
    stale = put_in(split.contract.hash, "stale")
    ir = put_in(ir.nodes["source"], stale)

    assert %{status: :accepted, diagnostics: draft_diagnostics} =
             Validator.report(ir, mode: :draft)

    assert Enum.any?(draft_diagnostics, fn diagnostic ->
             diagnostic.code == :stale_component_contract and diagnostic.severity == :warning
           end)

    assert %{status: :rejected, diagnostics: runnable_diagnostics} =
             Validator.report(ir, mode: :runnable)

    assert Enum.any?(runnable_diagnostics, fn diagnostic ->
             diagnostic.code == :stale_component_contract and diagnostic.severity == :error
           end)
  end

  test "automatic retry is rejected for effects without a reconciliation contract" do
    {:ok, tool} = Node.new("mutate", :tool_leaf, policy: %{max_retries: 2})

    {:ok, unsafe_ir} =
      IR.new("workflow:unsafe-retry", "Retry an opaque tool",
        nodes: %{tool.id => tool},
        acceptance: [%{id: "done", required: true}]
      )

    assert %{status: :accepted, diagnostics: draft_diagnostics} =
             Validator.report(unsafe_ir, mode: :draft)

    assert Enum.any?(draft_diagnostics, fn diagnostic ->
             diagnostic.code == :unsafe_effect_retry and diagnostic.severity == :warning
           end)

    assert %{status: :rejected, diagnostics: runnable_diagnostics} =
             Validator.report(unsafe_ir, mode: :runnable)

    assert Enum.any?(runnable_diagnostics, fn diagnostic ->
             diagnostic.code == :unsafe_effect_retry and diagnostic.severity == :error
           end)

    {:ok, writer} = Node.new("write", :artifact_writer, policy: %{scheduler: :io})

    {:ok, safe_ir} =
      IR.new("workflow:reconciled-retry", "Retry a content-addressed artifact write",
        nodes: %{writer.id => writer},
        acceptance: [%{id: "written", required: true}]
      )

    assert Validator.report(safe_ir, mode: :runnable).status == :accepted
  end

  defp workflow(source_type, target_type) do
    {:ok, source} = Node.new("source", source_type)
    {:ok, target} = Node.new("target", target_type)

    [source_port] = Map.keys(source.contract.outputs)
    [target_port] = Map.keys(target.contract.inputs)

    {:ok, edge} =
      Edge.new(
        %{node: source.id, port: source_port},
        %{node: target.id, port: target_port}
      )

    {:ok, ir} =
      IR.new("workflow:contracts", "Check contracts",
        nodes: %{source.id => source, target.id => target},
        edges: %{edge.id => edge},
        acceptance: [%{id: "done", required: true}]
      )

    ir
  end
end
