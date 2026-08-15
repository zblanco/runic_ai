defmodule RunicAI.Contract.PortComponentTest do
  use ExUnit.Case, async: true

  alias RunicAI.Contract.Component
  alias RunicAI.Contract.Port

  defp port(name, direction, type) do
    %{
      name: name,
      direction: direction,
      value: %{type: type},
      required: true,
      cardinality: "one",
      mode: "single"
    }
  end

  test "ports require exact transport semantics and assignable values" do
    output = Port.new!(port("count", "output", "integer"))
    input = Port.new!(port("amount", "input", "number"))

    assert Port.connectable?(output, input)

    batched_input =
      Port.new!(%{
        name: "amounts",
        direction: "input",
        value: %{type: "number"},
        cardinality: "many",
        mode: "batch"
      })

    assert {:error, [%{message: "port cardinality and mode do not match"}]} =
             Port.connectability(output, batched_input)
  end

  test "component semantics round trip with a verifiable stable hash" do
    component =
      Component.new!(%{
        key: "runic_ai.generate_text",
        contract_version: "1.0.0",
        shape: "step",
        inputs: [port("prompt", "input", "string")],
        outputs: [port("text", "output", "string")],
        effects: ["llm", "network"],
        replay: "effectful",
        retry: true,
        idempotency: "request_key",
        implementation: %{kind: "builtin", id: "generate_text", version: "1"}
      })

    encoded = Component.encode(component)
    assert encoded["semantic_hash"] == Component.semantic_hash(component)
    assert {:ok, ^component} = encoded |> Jason.encode!() |> Jason.decode!() |> Component.decode()
  end

  test "runtime bindings cannot leak into component specifications" do
    input = %{
      key: "runic_ai.bad",
      contract_version: "1",
      shape: "step",
      inputs: [],
      outputs: [],
      implementation: %{kind: "builtin", id: "bad", function: "hidden"}
    }

    assert {:error, [%{path: ["implementation"], message: message}]} = Component.new(input)
    assert message =~ "runtime binding fields"
  end

  test "effectful retries require an explicit idempotency policy" do
    input = %{
      key: "runic_ai.effect",
      contract_version: "1",
      shape: "step",
      inputs: [],
      outputs: [],
      effects: ["external_mutation"],
      replay: "effectful",
      retry: true,
      implementation: %{kind: "builtin", id: "effect"}
    }

    assert {:error, issues} = Component.new(input)
    assert %{path: ["retry"], message: message} = Enum.find(issues, &(&1.path == ["retry"]))
    assert message =~ "idempotency"
  end
end
