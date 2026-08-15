defmodule RunicAI.Agent.ContinueDecisionTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.ContinueDecision

  test "creates continue decisions" do
    assert {:ok, decision} = ContinueDecision.continue(:continue)
    assert decision.action == :continue
  end

  test "normalizes boolean values" do
    assert {:ok, continue_decision} = ContinueDecision.from_value(true, reason: :custom)
    assert {:ok, stop_decision} = ContinueDecision.from_value(false, reason: :custom)

    assert continue_decision.action == :continue
    assert stop_decision.action == :stop
  end
end
