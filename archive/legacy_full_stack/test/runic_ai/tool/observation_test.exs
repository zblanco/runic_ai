defmodule RunicAI.Tool.ObservationTest do
  use ExUnit.Case, async: true

  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.Observation

  test "builds model-ready tool messages from call results" do
    call_request = CallRequest.new!("call_1", "get_weather", %{"location" => "Paris"})
    call_result = CallResult.ok!(call_request, %{weather: "sunny"})

    observation = Observation.from_call_result!(call_result)

    assert observation.message.role == :tool
    assert observation.message.name == "get_weather"
    assert observation.message.metadata.tool_call_id == "call_1"
    assert observation.message.content =~ "\"weather\":\"sunny\""
  end
end
