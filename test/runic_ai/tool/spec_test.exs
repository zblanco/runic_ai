defmodule RunicAI.Tool.SpecTest do
  use ExUnit.Case, async: true

  alias RunicAI.Tool.Binding
  alias RunicAI.Tool.Spec

  test "tool specifications hash and round trip without executors" do
    spec = spec()

    binding =
      Binding.new!(spec, fn arguments, _context -> {:ok, %{"echo" => arguments["text"]}} end)

    encoded = Spec.encode(spec)

    assert encoded["semantic_hash"] == Spec.semantic_hash(spec)
    assert {:ok, ^spec} = encoded |> Jason.encode!() |> Jason.decode!() |> Spec.decode()
    refute inspect(encoded) =~ inspect(binding.executor)
    refute Map.has_key?(encoded, "executor")
  end

  test "unsafe effects cannot opt into retry without idempotency" do
    input =
      spec_input()
      |> Map.merge(%{effects: ["external_mutation"], replay: "unsafe", retry: true})

    assert {:error, issues} = Spec.new(input)
    assert Enum.any?(issues, &(&1.path == ["retry"] and &1.message =~ "idempotency"))
  end

  def spec do
    Spec.new!(spec_input())
  end

  defp spec_input do
    %{
      name: "test.echo",
      version: "1",
      description: "Echo text",
      input: %{
        type: "object",
        properties: %{text: %{type: "string"}},
        required: ["text"],
        additional_properties: false
      },
      output: %{
        type: "object",
        properties: %{echo: %{type: "string"}},
        required: ["echo"],
        additional_properties: false
      },
      effects: ["pure"]
    }
  end
end
