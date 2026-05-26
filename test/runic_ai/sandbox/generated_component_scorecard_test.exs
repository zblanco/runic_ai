defmodule RunicAI.Sandbox.GeneratedComponentScorecardTest do
  use ExUnit.Case, async: true

  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentScorecard

  test "separates passing contract verification and final objective status" do
    component = generated_component()

    assert {:ok, scorecard} =
             GeneratedComponentScorecard.run(component,
               objective_scorecard: %{
                 objective_status: :objective_incomplete,
                 residual_risks: ["artifact text was empty"]
               }
             )

    assert scorecard.component_id == "generated:parser"
    assert scorecard.contract_status == :pass
    assert scorecard.verification_status == :pass
    assert scorecard.final_objective_status == :objective_incomplete
    assert scorecard.promotable?
    assert scorecard.contract_risks == []
    assert scorecard.verification_risks == []
    assert scorecard.objective_residual_risks == ["artifact text was empty"]
  end

  test "flags incomplete contracts separately from failed verification" do
    component =
      generated_component(
        source_artifacts: [],
        test_artifacts: [],
        interface: %{inputs: [], outputs: []},
        verification: %{status: :failed},
        promotion_status: :draft
      )

    assert {:ok, scorecard} = GeneratedComponentScorecard.run(component)

    assert scorecard.contract_status == :incomplete
    assert scorecard.verification_status == :failed
    assert scorecard.final_objective_status == :not_evaluated
    refute scorecard.promotable?
    assert "source artifacts are missing" in scorecard.contract_risks
    assert "declared outputs are missing" in scorecard.contract_risks
    assert "verification status is not passing" in scorecard.verification_risks
    assert "test artifacts are missing" in scorecard.verification_risks
  end

  test "validates generated component input before scoring" do
    assert {:error, error} = GeneratedComponentScorecard.run(%{id: "missing-fields"})

    assert error.kind == :validation
    assert error.message =~ "name"
  end

  defp generated_component(overrides \\ []) do
    [
      id: "generated:parser",
      name: "Parser",
      language: :bash,
      runtime: :bash,
      entrypoint: "parser.sh:run",
      source_artifacts: [%{ref: "artifact://parser.sh"}],
      test_artifacts: [%{ref: "artifact://test_parser.sh"}],
      interface: %{
        inputs: [%{name: "input", type: "string"}],
        outputs: [%{name: "rows", type: "records"}]
      },
      verification: %{status: :pass, command: "bash test_parser.sh"},
      promotion_status: :verified
    ]
    |> Keyword.merge(overrides)
    |> GeneratedComponent.new!()
  end
end
