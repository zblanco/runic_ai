defmodule RunicAI.Coding.ReviewGateTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Coding.ReviewGate
  alias RunicAI.Control.GuardRequest
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.ExecutionPlan

  test "allows render_mermaid as a read-only coding visualization tool" do
    call =
      CallRequest.new!("call-render", "render_mermaid", %{
        "path" => "guides/mental-model.md",
        "diagram_index" => 1,
        "format" => "text",
        "color" => "auto"
      })

    request =
      GuardRequest.new!(:pre_tool, State.new!(), execution_plan: ExecutionPlan.new!([call]))

    decision = ReviewGate.evaluate(request)

    assert decision.action == :allow
    assert decision.reason == :safe_coding_tool_plan
  end

  test "allows extract_diagrams as a read-only coding visualization tool" do
    call =
      CallRequest.new!("call-extract", "extract_diagrams", %{
        "path" => "livebooks/rlm-coding-agent.livemd",
        "query" => "RLM agents"
      })

    request =
      GuardRequest.new!(:pre_tool, State.new!(), execution_plan: ExecutionPlan.new!([call]))

    decision = ReviewGate.evaluate(request)

    assert decision.action == :allow
    assert decision.reason == :safe_coding_tool_plan
  end
end
