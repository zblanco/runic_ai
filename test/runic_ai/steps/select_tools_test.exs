defmodule RunicAI.Steps.SelectToolsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Steps.SelectTools
  alias RunicAI.Tool.Definition

  test "filters visible tools with a selector function" do
    turn_request = TurnRequest.new!(State.new!(), input_message: "Hi", model: "test:model")

    weather =
      Definition.new!(
        name: "get_weather",
        description: "Get weather",
        parameter_schema: [],
        executor: fn _args -> {:ok, "sunny"} end
      )

    time =
      Definition.new!(
        name: "get_time",
        description: "Get time",
        parameter_schema: [],
        executor: fn _args -> {:ok, "12:00"} end
      )

    selection =
      SelectTools.select!(turn_request,
        registry: [weather, time],
        selector: fn _turn_request, _registry -> ["get_time"] end
      )

    assert Enum.map(selection.visible_tools, & &1.name) == ["get_time"]
  end
end
