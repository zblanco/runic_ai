defmodule RunicAI.CandidateTest do
  use ExUnit.Case, async: true

  alias RunicAI.Candidate.Registry
  alias RunicAI.Candidate.SelectionPolicy
  alias RunicAI.Recipes.ChatAgentKernel

  test "selects explicit candidates from a registry" do
    registry =
      Registry.new!([
        [id: "a", recipe: ChatAgentKernel, recipe_opts: [model: "a"]],
        [id: "b", recipe: ChatAgentKernel, recipe_opts: [model: "b"]]
      ])

    policy = SelectionPolicy.new!(strategy: :explicit, candidate_id: "b")

    assert {:ok, assignment} = SelectionPolicy.select(policy, registry, session_id: "session")
    assert assignment.candidate_id == "b"
    assert assignment.candidate.recipe_opts[:model] == "b"
  end

  test "hash strategy is deterministic for a session id" do
    registry =
      Registry.new!([
        [id: "a", recipe: ChatAgentKernel, recipe_opts: [model: "a"]],
        [id: "b", recipe: ChatAgentKernel, recipe_opts: [model: "b"]]
      ])

    policy = SelectionPolicy.new!(strategy: :hash)

    assert {:ok, first} = SelectionPolicy.select(policy, registry, session_id: "session-1")
    assert {:ok, second} = SelectionPolicy.select(policy, registry, session_id: "session-1")
    assert first.candidate_id == second.candidate_id
  end
end
