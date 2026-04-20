defmodule RunicAI.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry

  test "stores ordered tools and fetches them by name" do
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

    assert Registry.names(registry) == ["get_weather", "get_time"]
    assert {:ok, ^time} = Registry.fetch(registry, "get_time")
  end
end
