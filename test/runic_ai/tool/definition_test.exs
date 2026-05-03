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

  test "coerces common model-emitted scalar argument strings before validation" do
    definition =
      Definition.new!(
        name: "search_text",
        description: "Search text",
        parameter_schema: [
          query: [type: :string, required: true],
          context_lines: [type: :non_neg_integer, default: 0],
          limit: [type: :pos_integer, default: 20],
          include_hidden: [type: :boolean, default: false],
          paths: [type: {:list, :string}, default: []]
        ],
        executor: fn args -> {:ok, args} end
      )

    input = %{
      "query" => "MMDFLUX",
      "context_lines" => "3",
      "limit" => "20",
      "include_hidden" => "false",
      "paths" => "guides/mental-model.md"
    }

    assert {:ok, validated_arguments} = Definition.validate_arguments(definition, input)
    assert arg(validated_arguments, :context_lines) == 3
    assert arg(validated_arguments, :limit) == 20
    assert arg(validated_arguments, :include_hidden) == false
    assert arg(validated_arguments, :paths) == ["guides/mental-model.md"]

    assert {:ok, executed_arguments} = Definition.execute(definition, input)
    assert arg(executed_arguments, :context_lines) == 3
  end

  test "keeps invalid scalar strings invalid after coercion pass" do
    definition =
      Definition.new!(
        name: "search_text",
        description: "Search text",
        parameter_schema: [
          query: [type: :string, required: true],
          context_lines: [type: :non_neg_integer, default: 0]
        ],
        executor: fn args -> {:ok, args} end
      )

    assert {:error, error} =
             Definition.validate_arguments(definition, %{
               "query" => "MMDFLUX",
               "context_lines" => "three"
             })

    assert error.kind == :validation
    assert error.message == "tool arguments failed validation"
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

  defp arg(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
