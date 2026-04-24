defmodule RunicAI.RLM.PlanningTest do
  use ExUnit.Case, async: true

  alias RunicAI.RLM
  alias RunicAI.RLM.Continuation
  alias RunicAI.RLM.CostEstimate
  alias RunicAI.RLM.Environments.InMemory
  alias RunicAI.RLM.Episode
  alias RunicAI.RLM.PlanNode
  alias RunicAI.RLM.PlanPatch
  alias RunicAI.RLM.Policy
  alias RunicAI.RLM.Probe

  test "default planner creates a bounded split map reduce plan" do
    {:ok, environment} = InMemory.init()

    {:ok, source_ref, _environment} =
      InMemory.put_source(environment, String.duplicate("a", 25), id: "doc")

    policy = Policy.new!(leaf_window: 10, max_depth: 1)
    probe = Probe.new!(source_ref, 25)

    {:ok, plan} = RLM.plan(:summarization, [source_ref], policy: policy, probes: [probe])

    assert Enum.map(plan.nodes, & &1.op) == [:split, :map_leaf, :reduce]
    assert plan.cost_estimate.leaf_calls == 3
    assert plan.cost_estimate.reducer_calls == 1
    assert plan.policy.leaf_window == 10
  end

  test "cost estimates accept string-keyed maps without atomizing input" do
    {:ok, estimate} =
      CostEstimate.from_input(%{
        "leaf_calls" => 2,
        "environment_reads" => 3,
        "latency_class" => :medium,
        "assumptions" => ["probe-based estimate"],
        "metadata" => %{"source" => "planner"}
      })

    assert estimate.leaf_calls == 2
    assert estimate.environment_reads == 3
    assert estimate.latency_class == :medium
    assert estimate.assumptions == ["probe-based estimate"]
    assert estimate.metadata == %{"source" => "planner"}
  end

  test "plan patches and episodes are typed continuation boundaries" do
    patch =
      PlanPatch.new!(
        [PlanNode.new!("inspect-more", :map_leaf, parent_ids: ["reduce"])],
        connect_to: ["reduce"],
        metadata: %{reason: :coverage_gap}
      )

    continuation = Continuation.new!(patch, episode_id: "episode-1")

    episode =
      Episode.new!(:extended, "Need one more focused pass",
        id: "episode-1",
        continuation: continuation
      )

    assert episode.status == :extended
    assert episode.continuation.next == patch
    assert hd(patch.nodes).id == "inspect-more"
  end
end
