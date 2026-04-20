defmodule RunicAI.Tool.CallResultTest do
  use ExUnit.Case, async: true

  alias RunicAI.Error
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.CallResult

  test "builds retry results with normalized errors" do
    call_request = CallRequest.new!("call_1", "get_weather", %{"location" => "Paris"})
    error = Error.timeout("tool timed out", retryable?: true)

    call_result = CallResult.retry!(call_request, error)

    assert call_result.status == :retry
    assert call_result.error.message == "tool timed out"
  end
end
