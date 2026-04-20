defmodule RunicAI.Steps.AttachVisibleToolsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Steps.AttachVisibleTools
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry
  alias RunicAI.Tool.Selection

  test "attaches visible tools into llm opts while preserving existing opts" do
    turn_request =
      TurnRequest.new!(State.new!(),
        input_message: "Hi",
        model: "test:model",
        llm_opts: [temperature: 0.2]
      )

    weather =
      Definition.new!(
        name: "get_weather",
        description: "Get weather",
        parameter_schema: [],
        executor: fn _args -> {:ok, "sunny"} end
      )

    selection = Selection.new!(Registry.new!([weather]), [weather])
    attached_turn_request = AttachVisibleTools.attach!(turn_request, selection)

    assert attached_turn_request.llm_opts[:temperature] == 0.2
    assert length(attached_turn_request.llm_opts[:tools]) == 1
  end

  test "can override tool choice for the current turn" do
    turn_request =
      TurnRequest.new!(State.new!(),
        input_message: "Hi",
        model: "test:model"
      )

    weather =
      Definition.new!(
        name: "get_weather",
        description: "Get weather",
        parameter_schema: [],
        executor: fn _args -> {:ok, "sunny"} end
      )

    selection = Selection.new!(Registry.new!([weather]), [weather])

    attached_turn_request =
      AttachVisibleTools.attach!(turn_request, selection, tool_choice: :none)

    assert attached_turn_request.llm_opts[:tool_choice] == :none
    assert length(attached_turn_request.llm_opts[:tools]) == 1
  end
end
