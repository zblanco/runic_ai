defmodule RunicAI.Context.RuntimeContextContractsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Context.HorizonPolicy
  alias RunicAI.Context.LineageSnapshot
  alias RunicAI.Context.RestorePlan

  test "validates horizon and restore policies" do
    assert %HorizonPolicy{checkpoint_mode: :on_turn, restore_mode: :selective} =
             HorizonPolicy.new!(checkpoint_mode: :on_turn, restore_mode: :selective)

    assert %RestorePlan{mode: :selective, refs: ["context:a"]} =
             RestorePlan.new!(mode: :selective, refs: ["context:a"])
  end

  test "creates lineage snapshots tied to runtime session ids" do
    snapshot = LineageSnapshot.new!("session-a", snapshot: %{summary: "prior work"})

    assert snapshot.session_id == "session-a"
    assert snapshot.snapshot.summary == "prior work"
  end
end
