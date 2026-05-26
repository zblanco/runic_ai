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

  test "reviews sandbox code execution with structured policy details" do
    call =
      CallRequest.new!("call-code", "execute_code", %{
        "runtime" => "python",
        "code" => "print('sandbox review')",
        "network" => "host",
        "timeout_ms" => 5_000,
        "files" => %{"input.txt" => "sample"},
        "workspace" => %{"mode" => "bind", "persist?" => true}
      })

    request =
      GuardRequest.new!(:pre_tool, State.new!(), execution_plan: ExecutionPlan.new!([call]))

    decision = ReviewGate.evaluate(request)

    assert decision.action == :review
    assert decision.reason == :sandbox_network_policy_escalation
    assert decision.metadata.review_required?

    selected = decision.details.selected
    assert selected.tool_name == "execute_code"
    assert selected.runtime == "python"
    assert selected.network == :host
    assert selected.code_bytes == byte_size("print('sandbox review')")
    assert selected.input_files == [%{path: "input.txt", bytes: 6}]
    assert selected.workspace[:persist?]
    assert :network in selected.policy_escalations
    assert :workspace_export in selected.policy_escalations
  end
end
