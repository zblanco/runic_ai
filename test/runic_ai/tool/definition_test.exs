defmodule RunicAI.Tool.DefinitionTest do
  use ExUnit.Case, async: true

  alias RunicAI.Error
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

  test "preserves RunicAI errors returned by callbacks" do
    definition =
      Definition.new!(
        name: "read_file",
        description: "Read a file",
        parameter_schema: [path: [type: :string, required: true]],
        executor: fn _args ->
          {:error,
           Error.validation("path must be workspace-relative",
             source: __MODULE__,
             details: %{path: "/tmp/project/lib/demo.ex"}
           )}
        end
      )

    assert {:error, error} =
             Definition.execute(definition, %{"path" => "/tmp/project/lib/demo.ex"})

    assert error.kind == :validation
    assert error.message == "path must be workspace-relative"
    assert error.source == __MODULE__
  end
end
