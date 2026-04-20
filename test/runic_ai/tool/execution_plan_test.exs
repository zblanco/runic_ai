defmodule RunicAI.Tool.ExecutionPlanTest do
  use ExUnit.Case, async: true

  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.ExecutionPlan

  test "builds a staged execution plan" do
    call_request = CallRequest.new!("call_1", "get_weather", %{"location" => "Paris"})

    plan =
      ExecutionPlan.new!([call_request],
        policy: [mode: {:staged, [["call_1"]]}],
        groups: [["call_1"]]
      )

    assert plan.groups == [["call_1"]]
    assert plan.policy.mode == {:staged, [["call_1"]]}
  end
end
