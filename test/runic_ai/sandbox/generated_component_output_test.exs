defmodule RunicAI.Sandbox.GeneratedComponentOutputTest do
  use ExUnit.Case, async: true

  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentOutput

  test "parses JSON stdout and validates required typed outputs" do
    component =
      component(outputs: [%{name: "rows", type: "records", required: true}])

    assert {:ok, result} =
             GeneratedComponentOutput.from_execution(component, %{
               stdout: ~s({"rows":[{"id":1},{"id":2}]}),
               stderr: "",
               exit_status: 0
             })

    assert result.value == %{"rows" => [%{"id" => 1}, %{"id" => 2}]}
    assert result.validation.status == :accepted
    assert result.validation.present_outputs == ["rows"]
  end

  test "accepts a single direct output value for output-shaped interfaces" do
    component = component(outputs: [%{name: "output", type: "string", required: true}])

    assert {:ok, result} = GeneratedComponentOutput.parse(component, "plain text", format: :text)
    assert result.value == "plain text"
    assert result.validation.present_outputs == ["output"]
  end

  test "rejects missing required outputs" do
    component =
      component(outputs: [%{name: "summary", type: "string", required: true}])

    assert {:error, error} =
             GeneratedComponentOutput.parse(component, ~s({"other":"value"}), format: :json)

    assert error.kind == :validation
    assert error.details.missing_outputs == ["summary"]
    assert error.details.type_errors == []
  end

  test "rejects output type mismatches" do
    component =
      component(outputs: [%{name: "rows", type: "records", required: true}])

    assert {:error, error} =
             GeneratedComponentOutput.parse(component, ~s({"rows":["bad"]}), format: :json)

    assert error.kind == :validation
    assert error.details.missing_outputs == []
    assert [%{output: "rows", expected: "records", actual: "array"}] = error.details.type_errors
  end

  test "strict JSON mode rejects non-JSON output" do
    component = component(outputs: [%{name: "output", type: "string", required: true}])

    assert {:error, error} = GeneratedComponentOutput.parse(component, "not json", format: :json)
    assert error.kind == :validation
    assert error.message =~ "not valid JSON"
  end

  defp component(opts) do
    GeneratedComponent.new!(
      id: "generated:output",
      name: "Output component",
      language: :python,
      runtime: :python,
      entrypoint: "component.py:run",
      interface: %{outputs: Keyword.fetch!(opts, :outputs)},
      verification: %{commands: ["python -m pytest"]},
      promotion_status: :draft
    )
  end
end
