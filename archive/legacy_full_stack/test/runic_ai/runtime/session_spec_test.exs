defmodule RunicAI.Runtime.SessionSpecTest do
  use ExUnit.Case, async: true

  alias RunicAI.Candidate.Spec, as: CandidateSpec
  alias RunicAI.Recipes.ChatAgentKernel
  alias RunicAI.Recipes.IntegratedChatAgent
  alias RunicAI.Runtime.Backends.InMemory
  alias RunicAI.Runtime.SessionSpec

  test "infers turn-processor defaults" do
    {:ok, spec} =
      SessionSpec.new(
        id: "session-a",
        recipe: ChatAgentKernel,
        recipe_opts: [model: "test:model"]
      )

    assert spec.kind == :turn_processor
    assert spec.driver == RunicAI.Harness.TurnProcessor
    assert spec.backend == InMemory
    assert spec.policy.max_reactions == 16
  end

  test "infers integrated defaults" do
    {:ok, spec} =
      SessionSpec.new(
        id: "session-b",
        recipe: IntegratedChatAgent,
        recipe_opts: [model: "test:model"]
      )

    assert spec.kind == :integrated
    assert spec.driver == RunicAI.Harness.Integrated
  end

  test "assigns an explicit candidate at session start" do
    candidate =
      CandidateSpec.new!(
        id: "candidate-a",
        recipe: ChatAgentKernel,
        recipe_opts: [model: "test:model", system: "candidate"]
      )

    {:ok, spec} =
      SessionSpec.new(
        id: "session-c",
        candidate: candidate,
        recipe_opts: [system: "override"]
      )

    assert spec.recipe == ChatAgentKernel
    assert spec.recipe_opts[:model] == "test:model"
    assert spec.recipe_opts[:system] == "override"
    assert spec.candidate_assignment.candidate_id == "candidate-a"
  end
end
