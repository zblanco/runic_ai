defmodule RunicAI.Contract.ValueTest do
  use ExUnit.Case, async: true

  alias RunicAI.Contract.Value

  @document_contract %{
    type: "object",
    additional_properties: false,
    properties: %{
      title: %{type: "string"},
      score: %{type: "number", nullable: true},
      tags: %{type: "list", items: %{type: "string"}, max_items: 3}
    },
    required: ["title", "tags"]
  }

  test "canonical contracts round trip through JSON" do
    contract = Value.new!(@document_contract)
    encoded = Value.encode(contract)

    assert encoded["$contract"] == "runic.contract/value/v1"
    assert {:ok, ^contract} = encoded |> Jason.encode!() |> Jason.decode!() |> Value.decode()
    assert Value.semantic_hash(contract) == Value.semantic_hash(encoded)
  end

  test "validates nested values with exact paths" do
    contract = Value.new!(@document_contract)

    assert :ok = Value.validate_value(contract, %{"title" => "Report", "tags" => ["a"]})

    assert {:error, issues} =
             Value.validate_value(contract, %{
               "score" => false,
               "tags" => ["a", "b", "c", "d"],
               "extra" => true
             })

    assert %{path: ["title"], message: "is required"} in issues
    assert %{path: ["extra"], message: "is not allowed"} in issues
    assert %{path: ["score"], message: "expected number"} in issues
    assert %{path: ["tags"], message: "must contain at most 3 items"} in issues
  end

  test "assignability is conservative and reports the incompatible path" do
    source =
      Value.new!(%{
        type: "object",
        properties: %{name: %{type: "string"}, age: %{type: "integer"}},
        required: ["name", "age"]
      })

    compatible_target =
      Value.new!(%{
        type: "object",
        properties: %{name: %{type: "string"}, age: %{type: "number"}},
        required: ["name", "age"]
      })

    incompatible_target =
      Value.new!(%{
        type: "object",
        properties: %{name: %{type: "string"}, city: %{type: "string"}},
        required: ["name", "city"]
      })

    assert Value.assignable?(source, compatible_target)

    assert {:error, [%{path: ["city"], message: message}]} =
             Value.assignability(source, incompatible_target)

    assert message =~ "not guaranteed"
  end

  test "projects the inert contract to JSON Schema" do
    schema = @document_contract |> Value.new!() |> Value.to_json_schema()

    assert schema["type"] == "object"
    assert schema["required"] == ["title", "tags"]
    assert schema["properties"]["score"]["anyOf"] == [%{"type" => "number"}, %{"type" => "null"}]
  end

  test "unknown external enum values do not create atoms" do
    unknown = "unknown_contract_kind_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:error, [%{path: ["type"]}]} = Value.decode(%{"type" => unknown})
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end
end
