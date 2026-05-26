defmodule RunicAI.Sandbox.GeneratedComponentProposalPromptTest do
  use ExUnit.Case, async: true

  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentProposalPrompt

  test "manifest exposes generated component enum values and default policy" do
    manifest = GeneratedComponentProposalPrompt.manifest()

    assert manifest.languages == Enum.map(GeneratedComponent.languages(), &Atom.to_string/1)
    assert manifest.promotion_statuses == ["draft", "verified", "promoted", "rejected"]
    assert manifest.default_policy.network == "disabled"
    assert manifest.default_policy.filesystem == "sandbox_only"
    assert manifest.default_policy.promotion_requires_review
    assert "verification.commands" in manifest.required_contract_sections

    assert %{default_language: "node"} =
             GeneratedComponentProposalPrompt.manifest(default_language: "node")
  end

  test "prompt asks for a contract only and includes objective context and shape" do
    prompt =
      GeneratedComponentProposalPrompt.prompt("Build a CSV normalizer",
        context_summary: "Inputs are CSV strings from tickets.",
        context_refs: [%{ref: "artifact://sample.csv", kind: "sample"}],
        default_language: :python,
        capability_profile: "sandbox_python_read"
      )

    assert prompt =~ "Build a CSV normalizer"
    assert prompt =~ "Inputs are CSV strings from tickets."
    assert prompt =~ "artifact://sample.csv"
    assert prompt =~ "contract proposal only"
    assert prompt =~ "Do not write source code"
    assert prompt =~ ~s("promotion_status":"draft")
    assert prompt =~ ~s("network":"disabled")
    assert prompt =~ ~s("capability_profile":"sandbox_python_read")
  end

  test "shape example is valid generated component input" do
    example =
      GeneratedComponentProposalPrompt.shape_example("Parse JSONL records",
        id: "generated:jsonl_parser",
        default_language: "python",
        provenance: [%{source: :test}]
      )

    assert example.id == "generated:jsonl_parser"
    assert example.language == "python"
    assert example.promotion_status == "draft"
    assert [%{"source" => "test"}] = example.provenance

    assert {:ok, component} =
             GeneratedComponentProposalPrompt.contract_from_proposal(example)

    assert component.id == "generated:jsonl_parser"
    assert component.language == :python
    refute GeneratedComponent.promotable?(component)
  end

  test "repair prompt includes diagnostics and keeps repair scoped to the contract" do
    repair =
      GeneratedComponentProposalPrompt.repair_prompt(
        "Parse invoices",
        %{language: "ruby"},
        [%{code: :invalid_language, path: ["language"]}]
      )

    assert repair =~ "repairing an invalid RunicAI sandbox generated-component contract"
    assert repair =~ "invalid_language"
    assert repair =~ ~s("language":"ruby")
    assert repair =~ "Do not generate source code or tests"
    assert repair =~ ~s("promotion_status":"draft")
  end
end
