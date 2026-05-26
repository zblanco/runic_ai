defmodule RunicAI.Sandbox.GeneratedComponentPromotionPolicyTest do
  use ExUnit.Case, async: true

  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentPromotionPolicy

  test "allows ephemeral use for promotable verified components" do
    assert {:ok, decision} =
             GeneratedComponentPromotionPolicy.evaluate(component(), target: :ephemeral)

    assert decision.action == :keep_ephemeral
    assert decision.reason == :ephemeral_component
    assert decision.details.component_id == "generated:promotable"
    assert decision.details.policy_escalations == []

    assert {:ok, unchanged} =
             GeneratedComponentPromotionPolicy.apply_decision(component(), decision)

    assert unchanged.promotion_status == :verified
  end

  test "allows durable artifact promotion without host materialization" do
    assert {:ok, decision} =
             GeneratedComponentPromotionPolicy.evaluate(component(), target: "artifact")

    assert decision.action == :store_artifact
    assert decision.reason == :durable_artifact_allowed

    assert {:ok, promoted} =
             GeneratedComponentPromotionPolicy.apply_decision(component(), decision)

    assert promoted.promotion_status == :promoted
    assert promoted.metadata.promotion.action == :store_artifact
    assert promoted.metadata.promotion.target == :artifact
  end

  test "requires review before host repo materialization" do
    assert {:ok, decision} =
             GeneratedComponentPromotionPolicy.evaluate(component(), target: :host_repo)

    assert decision.action == :review
    assert decision.reason == :host_materialization_requires_review
    assert %ReviewRequest{} = decision.review_request
    assert decision.review_request.kind == :generated_component_promotion
    assert decision.review_request.details.required_decision == :human_review

    assert {:error, error} =
             GeneratedComponentPromotionPolicy.apply_decision(component(), decision)

    assert error.kind == :validation
    assert error.message =~ "approved review decision"

    approved =
      ReviewDecision.new!(decision.review_request.resume_key, :approved,
        actor: "tester",
        metadata: %{reviewed?: true}
      )

    assert {:ok, promoted} =
             GeneratedComponentPromotionPolicy.apply_decision(component(), decision,
               review_decision: approved
             )

    assert promoted.promotion_status == :promoted
    assert promoted.metadata.promotion.reviewed_by == "tester"
  end

  test "rejects failed or incomplete components" do
    draft =
      GeneratedComponent.new!(
        id: "generated:draft",
        name: "Draft",
        language: :python,
        runtime: :python,
        entrypoint: "component.py:run",
        source_artifacts: [],
        verification: %{status: :failed},
        promotion_status: :draft
      )

    assert {:ok, decision} = GeneratedComponentPromotionPolicy.evaluate(draft, target: :artifact)
    assert decision.action == :reject
    assert decision.reason == :component_not_promotable
    refute decision.details.promotable?

    assert {:ok, rejected} = GeneratedComponentPromotionPolicy.apply_decision(draft, decision)
    assert rejected.promotion_status == :rejected
  end

  test "policy escalations force review even for artifact targets" do
    component =
      component(metadata: %{policy: %{network: "enabled", filesystem: "sandbox_only"}})

    assert {:ok, decision} =
             GeneratedComponentPromotionPolicy.evaluate(component, target: :artifact)

    assert decision.action == :review
    assert decision.reason == :policy_escalation
    assert decision.details.policy_escalations == [:network]
  end

  defp component(opts \\ []) do
    GeneratedComponent.new!(
      id: Keyword.get(opts, :id, "generated:promotable"),
      name: "Promotable",
      language: :python,
      runtime: :python,
      entrypoint: "component.py:run",
      source_artifacts: [%{ref: "artifact://component.py", path: "component.py"}],
      test_artifacts: [%{ref: "artifact://test_component.py", path: "test_component.py"}],
      interface: %{outputs: [%{name: "output", type: "object"}]},
      verification: %{status: :pass, command: "python -m pytest"},
      promotion_status: :verified,
      metadata:
        Keyword.get(opts, :metadata, %{
          policy: %{network: "disabled", filesystem: "sandbox_only"}
        })
    )
  end
end
