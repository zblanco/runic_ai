defmodule RunicAI.Tool.SelectionTest do
  use ExUnit.Case, async: true

  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry
  alias RunicAI.Tool.Selection

  test "selects a visible subset and converts it to ReqLLM tools" do
    weather =
      Definition.new!(
        name: "get_weather",
        description: "Get weather",
        parameter_schema: [location: [type: :string, required: true]],
        executor: fn _args -> {:ok, "sunny"} end
      )

    time =
      Definition.new!(
        name: "get_time",
        description: "Get time",
        parameter_schema: [],
        executor: fn _args -> {:ok, "12:00"} end
      )

    registry = Registry.new!([weather, time])
    selection = Selection.new!(registry, ["get_time"])

    assert Selection.visible_names(selection) == ["get_time"]
    assert selection.hidden_tools == ["get_weather"]
    assert {:ok, [req_tool]} = Selection.to_req_llm_tools(selection)
    assert req_tool.name == "get_time"
  end
end
