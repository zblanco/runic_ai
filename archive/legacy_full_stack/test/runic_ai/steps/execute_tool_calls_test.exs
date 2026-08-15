defmodule RunicAI.Steps.ExecuteToolCallsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Steps.ExecuteToolCalls
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Tool.Registry
  alias RunicAI.Tool.Selection

  test "executes parallel batches and preserves request ordering" do
    first =
      Definition.new!(
        name: "first_tool",
        description: "First tool",
        parameter_schema: [],
        executor: fn _args ->
          Process.sleep(20)
          {:ok, "first"}
        end
      )

    second =
      Definition.new!(
        name: "second_tool",
        description: "Second tool",
        parameter_schema: [],
        executor: fn _args -> {:ok, "second"} end
      )

    selection = Selection.new!(Registry.new!([first, second]), [first, second])

    execution_plan =
      ExecutionPlan.new!(
        [
          CallRequest.new!("call_1", "first_tool", %{}, request_index: 0),
          CallRequest.new!("call_2", "second_tool", %{}, request_index: 1)
        ],
        policy: [mode: :parallel, max_concurrency: 2]
      )

    assert {:ok, batch_result} = ExecuteToolCalls.execute(execution_plan, selection)
    results = batch_result.results

    assert Enum.map(results, & &1.request.id) == ["call_1", "call_2"]
    assert Enum.map(results, & &1.output) == ["first", "second"]
  end
end
