defmodule RunicAI.Sandbox.GeneratedComponentCatalogContextTest do
  use ExUnit.Case, async: true

  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentCatalog
  alias RunicAI.Sandbox.GeneratedComponentCatalog.CapabilityGap

  test "summarizes catalog candidates for coordinator prompt context" do
    store = catalog_store()

    assert {:ok, context} =
             GeneratedComponentCatalog.prompt_context("Normalize invoice rows",
               generated_component_catalog: store,
               generated_component_intent_tags: [:parse, :normalize],
               generated_component_inputs: [%{name: "rows"}],
               generated_component_outputs: [%{name: "invoice_facts"}],
               generated_component_kind: :sandbox_execute,
               generated_component_runtime: :python,
               generated_component_policy: %{network: :disabled}
             )

    assert context.available?
    assert context.candidate_count == 1
    assert [%{id: "generated:invoice-normalizer", match_reasons: reasons}] = context.candidates
    assert :intent_tags_exact in reasons
    assert :input_signature_match in reasons
    assert :output_signature_match in reasons
  end

  test "derives a generation gap from a draft proposal and catalog search results" do
    store = catalog_store()

    draft =
      GeneratedComponent.new!(
        id: "generated:invoice-specialized",
        name: "Specialized invoice normalizer",
        language: :python,
        runtime: :python,
        entrypoint: "component.py:run",
        interface: %{
          inputs: [%{name: "rows", type: "list<object>"}],
          outputs: [%{name: "invoice_facts", type: "list<object>"}]
        },
        verification: %{commands: ["python -m pytest"]},
        promotion_status: :draft,
        metadata: %{intent_tags: [:parse, :normalize], policy: %{network: :disabled}}
      )

    assert {:ok, gap} =
             GeneratedComponentCatalog.gap_for_proposal("Normalize invoice rows", draft,
               generated_component_catalog: store
             )

    assert %CapabilityGap{} = gap
    assert gap.selected_action == :generate_leaf
    assert CapabilityGap.generation_allowed?(gap)
    assert CapabilityGap.candidate_ids(gap) == ["generated:invoice-normalizer"]
    assert gap.required_contract.inputs == [%{name: "rows", type: "list<object>"}]
    assert gap.metadata.generated_component_id == "generated:invoice-specialized"
  end

  test "prompt context includes matching negative evidence for avoidance" do
    failed =
      %{
        id: "negative:invoice-specialized",
        component_id: "generated:invoice-specialized",
        objective: "Normalize invoice rows",
        required_contract: %{
          intent_tags: [:parse, :normalize],
          inputs: [%{name: "rows"}],
          outputs: [%{name: "invoice_facts"}],
          runtime: :python
        },
        candidates: [],
        proof_id: "proof:invoice-specialized",
        command: "python -m pytest",
        diagnostics: %{stderr_preview: "assertion failed"},
        source_artifacts: [%{path: "component.py"}],
        test_artifacts: [%{path: "test_component.py"}],
        reason: :component_not_promotable
      }

    store = GeneratedComponentCatalog.new_store!(negative_evidence: [failed])

    assert {:ok, context} =
             GeneratedComponentCatalog.prompt_context("Normalize invoice rows",
               generated_component_catalog: store,
               generated_component_intent_tags: [:parse, :normalize],
               generated_component_inputs: [%{name: "rows"}],
               generated_component_outputs: [%{name: "invoice_facts"}],
               generated_component_runtime: :python
             )

    assert context.negative_evidence_count == 1

    assert [%{id: "negative:invoice-specialized", proof_id: "proof:invoice-specialized"}] =
             context.negative_evidence
  end

  defp catalog_store do
    component =
      GeneratedComponent.new!(
        id: "generated:invoice-normalizer",
        name: "Invoice normalizer",
        language: :python,
        runtime: :python,
        entrypoint: "component.py:run",
        source_artifacts: [%{path: "component.py", ref: "source:invoice"}],
        test_artifacts: [%{path: "test_component.py", ref: "test:invoice"}],
        interface: %{
          inputs: [%{name: "rows", type: "list<object>"}],
          outputs: [%{name: "invoice_facts", type: "list<object>"}]
        },
        verification: %{status: :pass, command: "python -m pytest"},
        promotion_status: :verified,
        metadata: %{intent_tags: [:parse, :normalize], network: :disabled}
      )

    entry = GeneratedComponentCatalog.entry_from_component(component) |> ok!()
    GeneratedComponentCatalog.new_store!(entries: [entry])
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, error}), do: raise(error.message)
end
