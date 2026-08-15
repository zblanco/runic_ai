defmodule RunicAI.Workflows.SubstrateLLMEvalTest do
  use ExUnit.Case, async: true

  alias RunicAI.LLM.TestClient
  alias RunicAI.Workflows.DSL
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.SubstrateLLMEval

  test "normalizes server-owned revisions and gives typed operations editable context" do
    {:ok, discover} = Node.new("discover", :source_discovery)

    {:ok, base} =
      IR.new("workflow:substrate-llm", "Evaluate authoring substrates",
        nodes: %{discover.id => discover},
        acceptance: [%{id: "measured", required: true}]
      )

    operations = [%{op: "set_policy", key: "max_runtime_ms", value: 5_000}]

    {:ok, edit} =
      Editor.apply(base, %{
        base_revision: base.revision,
        base_hash: IR.semantic_hash(base),
        operations: operations
      })

    authored = %{edit.ir | revision: base.revision}
    json = Jason.encode!(authored)
    {:ok, dsl} = DSL.render(authored)

    client = fn _model, prompt, _opts ->
      response =
        cond do
          String.contains?(prompt, "complete canonical JSON") -> json
          String.contains?(prompt, "complete Runic workflow DSL") -> dsl
          String.contains?(prompt, "Current editable manifest") -> Jason.encode!(operations)
        end

      {:ok, TestClient.result(response)}
    end

    assert {:ok, result} =
             SubstrateLLMEval.run_case(
               %{
                 id: "policy-repair",
                 instruction: "Set max_runtime_ms to 5000.",
                 base_ir: base,
                 target_ir: edit.ir
               },
               client: client
             )

    assert result.all_pass?
    assert Enum.all?(result.rows, &(&1.diagnostics.normalized_revision == 2))

    operations_row = Enum.find(result.rows, &(&1.arm == :typed_operations))
    assert operations_row.artifacts.prompt =~ ~s("id":"discover")
    assert operations_row.artifacts.prompt =~ ~s("component":"runic_ai/source_discovery")
  end
end
