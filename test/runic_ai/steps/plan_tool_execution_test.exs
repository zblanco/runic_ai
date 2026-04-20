defmodule RunicAI.Steps.PlanToolExecutionTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.TurnResult
  alias RunicAI.Message
  alias RunicAI.Steps.PlanToolExecution
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.ExecutionPolicy
  alias RunicAI.Tool.Registry
  alias RunicAI.Tool.Selection

  test "derives serial execution when any visible tool requires it" do
    tool_calls = [
      CallRequest.new!("call_1", "get_weather", %{location: "Paris"}, request_index: 0),
      CallRequest.new!("call_2", "get_time", %{}, request_index: 1)
    ]

    turn_result =
      TurnResult.tool_requests!(Message.new!(:assistant, ""),
        details: %{tool_calls: tool_calls}
      )

    weather =
      Definition.new!(
        name: "get_weather",
        description: "Get weather",
        parameter_schema: [location: [type: :string, required: true]],
        executor: fn _args -> {:ok, "sunny"} end,
        execution_policy: ExecutionPolicy.new!(mode: :serial)
      )

    time =
      Definition.new!(
        name: "get_time",
        description: "Get time",
        parameter_schema: [],
        executor: fn _args -> {:ok, "12:00"} end
      )

    selection = Selection.new!(Registry.new!([weather, time]), [weather, time])

    assert {:ok, execution_plan} = PlanToolExecution.plan(turn_result, selection)
    assert execution_plan.policy.mode == :serial
  end
end
