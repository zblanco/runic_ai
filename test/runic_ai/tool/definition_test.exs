defmodule RunicAI.Tool.DefinitionTest do
  use ExUnit.Case, async: true

  alias RunicAI.Tool.Definition

  test "validates arguments and executes the tool callback" do
    definition =
      Definition.new!(
        name: "get_weather",
        description: "Get weather for a city",
        parameter_schema: [location: [type: :string, required: true]],
        executor: fn %{location: location} -> {:ok, "sunny in #{location}"} end
      )

    assert {:ok, validated_arguments} =
             Definition.validate_arguments(definition, %{"location" => "Paris"})

    assert (Map.get(validated_arguments, :location) ||
              Map.get(validated_arguments, "location")) == "Paris"

    assert {:ok, "sunny in Paris"} = Definition.execute(definition, %{"location" => "Paris"})
  end
end
