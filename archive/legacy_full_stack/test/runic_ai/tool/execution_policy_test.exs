defmodule RunicAI.Tool.ExecutionPolicyTest do
  use ExUnit.Case, async: true

  alias RunicAI.Tool.ExecutionPolicy

  test "supports staged execution and halt actions" do
    policy = ExecutionPolicy.new!(mode: {:staged, [["call_1"], ["call_2"]]}, stop_on_error: :halt)

    assert policy.mode == {:staged, [["call_1"], ["call_2"]]}
    assert ExecutionPolicy.halt_action(policy) == :halt
  end
end
