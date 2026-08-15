defmodule RunicAI.Tool.BatchResultTest do
  use ExUnit.Case, async: true

  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.CallResult

  test "wraps normalized call results for workflow transport" do
    call_request = CallRequest.new!("call_1", "get_weather", %{location: "Paris"})
    call_result = CallResult.ok!(call_request, %{forecast: "sunny"})

    assert {:ok, batch_result} = BatchResult.new([call_result], metadata: %{source: :test})
    assert [%CallResult{status: :ok}] = batch_result.results
    assert batch_result.metadata == %{source: :test}
  end
end
