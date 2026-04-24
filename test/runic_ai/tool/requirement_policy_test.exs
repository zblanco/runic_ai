defmodule RunicAI.Tool.RequirementPolicyTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry
  alias RunicAI.Tool.RequirementPolicy
  alias RunicAI.Tool.Selection

  test "required policy forces tool choice before any tool batch" do
    turn_request =
      TurnRequest.new!(State.new!(),
        input_message: "Check the weather",
        model: "test:model"
      )

    assert RequirementPolicy.resolve_tool_choice!(:required, turn_request, selection()) ==
             :required
  end

  test "required policy relaxes to auto after tool observations" do
    state =
      State.new!(metadata: RequirementPolicy.mark_post_tool_turn(%{}))

    turn_request =
      TurnRequest.new!(state,
        model: "test:model"
      )

    assert RequirementPolicy.resolve_tool_choice!(:required, turn_request, selection()) == :auto
  end

  test "recipe opts reject raw recipe-level tool_choice" do
    assert_raise ArgumentError, ~r/recipe-level :tool_choice is not supported/, fn ->
      RequirementPolicy.from_recipe_opts!(tool_choice: :required)
    end
  end

  test "recipe opts reject raw llm tool_choice" do
    assert_raise ArgumentError, ~r/llm_opts\[:tool_choice\] is not supported/, fn ->
      RequirementPolicy.from_recipe_opts!(llm_opts: [tool_choice: :required])
    end
  end

  defp selection do
    weather =
      Definition.new!(
        name: "get_weather",
        description: "Get weather",
        parameter_schema: [],
        executor: fn _args -> {:ok, "sunny"} end
      )

    Selection.new!(Registry.new!([weather]), [weather])
  end
end
