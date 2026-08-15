defmodule RunicAI.Steps.AppendToolObservationsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Steps.AppendToolObservations
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.ExecutionPlan

  test "appends tool messages and clears pending actions" do
    state = State.new!(pending_action: %{kind: :tool_requests})
    call_request = CallRequest.new!("call_1", "get_weather", %{"location" => "Paris"})
    call_result = CallResult.ok!(call_request, %{weather: "sunny"})
    execution_plan = ExecutionPlan.new!([call_request])
    batch_result = BatchResult.new!([call_result])

    updated_state = AppendToolObservations.append!(state, execution_plan, batch_result)

    assert updated_state.pending_action == nil
    assert Enum.map(updated_state.conversation.messages, & &1.role) == [:tool]
  end

  test "halts state when stop_on_error requires it" do
    state = State.new!()
    call_request = CallRequest.new!("call_1", "get_weather", %{"location" => "Paris"})
    call_result = CallResult.error!(call_request, "boom")
    execution_plan = ExecutionPlan.new!([call_request], policy: [stop_on_error: :halt])
    batch_result = BatchResult.new!([call_result])

    updated_state = AppendToolObservations.append!(state, execution_plan, batch_result)

    assert updated_state.status == :halted
  end
end
