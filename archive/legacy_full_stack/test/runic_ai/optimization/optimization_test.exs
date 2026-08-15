defmodule RunicAI.OptimizationTest do
  use ExUnit.Case, async: true

  alias RunicAI.Optimization.Hook
  alias RunicAI.Optimization.Objective
  alias RunicAI.Optimization.Suggestion

  test "runs observational hooks and returns suggestions" do
    hook = fn artifact, _opts ->
      Suggestion.new!(:prompt_revision, "Prefer the candidate with more completed turns",
        confidence: 0.75,
        details: %{artifact: artifact}
      )
    end

    assert {:ok, [%Suggestion{} = suggestion]} = Hook.run(hook, %{winner: "a"})
    assert suggestion.kind == :prompt_revision
    assert suggestion.confidence == 0.75
  end

  test "validates optimization objectives" do
    assert %Objective{direction: :minimize} =
             Objective.new!(:latency, :elapsed_ms, direction: :minimize)
  end
end
