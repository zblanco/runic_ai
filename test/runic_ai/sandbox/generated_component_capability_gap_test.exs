defmodule RunicAI.Sandbox.GeneratedComponentCapabilityGapTest do
  use ExUnit.Case, async: true

  alias RunicAI.Sandbox.GeneratedComponentCatalog
  alias RunicAI.Sandbox.GeneratedComponentCatalog.CapabilityGap

  test "records catalog candidates and a generate-leaf decision" do
    assert {:ok, gap} =
             GeneratedComponentCatalog.capability_gap(
               objective: "Normalize invoice rows",
               required_contract: %{
                 inputs: [%{name: "rows"}],
                 outputs: [%{name: "invoice_facts"}]
               },
               candidates: [
                 %{
                   id: "generated:generic_csv_parser",
                   score: 42,
                   rejection_reason: "does not emit invoice facts"
                 }
               ],
               selected_action: :generate_leaf,
               reason: "No candidate matches the required invoice fact output."
             )

    assert %CapabilityGap{} = gap
    assert gap.selected_action == :generate_leaf
    assert CapabilityGap.generation_allowed?(gap)
    assert CapabilityGap.candidate_ids(gap) == ["generated:generic_csv_parser"]
  end

  test "requires reuse decisions to select one of the considered candidates" do
    assert {:error, error} =
             GeneratedComponentCatalog.capability_gap(
               objective: "Normalize invoice rows",
               candidates: [%{id: "generated:invoice_normalizer"}],
               selected_action: :reuse_exact,
               selected_component_id: "generated:missing",
               reason: "Use the exact catalog match."
             )

    assert error.kind == :validation
    assert error.details.selected_component_id == "generated:missing"
    assert error.details.candidate_ids == ["generated:invoice_normalizer"]
  end

  test "prevents generation decisions from selecting an existing component" do
    assert {:error, error} =
             GeneratedComponentCatalog.capability_gap(
               objective: "Normalize invoice rows",
               candidates: [%{id: "generated:invoice_normalizer"}],
               selected_action: :generate_leaf,
               selected_component_id: "generated:invoice_normalizer",
               reason: "Generate anyway."
             )

    assert error.kind == :validation
    assert error.details.selected_action == :generate_leaf
  end
end
