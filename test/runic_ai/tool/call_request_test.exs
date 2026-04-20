defmodule RunicAI.Tool.CallRequestTest do
  use ExUnit.Case, async: true

  alias RunicAI.LLM.TestClient
  alias RunicAI.Tool.CallRequest

  test "normalizes provider tool calls into call requests" do
    tool_call = TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")

    call_request = CallRequest.from_provider!(tool_call, request_index: 2)

    assert call_request.id == "call_1"
    assert call_request.tool_name == "get_weather"
    assert call_request.arguments == %{"location" => "Paris"}
    assert call_request.request_index == 2
  end
end
