defmodule RunicAI.Assistant.RLMBlueprintTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.FunctionBlueprint
  alias RunicAI.Assistant.RLM.WorkflowBlueprint

  test "constructs and validates a workflow blueprint" do
    split = ComponentBlueprint.new!("split", :source_splitter)
    write = ComponentBlueprint.new!("write", :artifact_writer, params: %{path: ".docs/out.md"})

    blueprint =
      WorkflowBlueprint.new!("Write report", [split, write],
        id: "assistant-test",
        sources: ["tmp/source.md"],
        edges: [%{from: "split", to: "write"}],
        stop_conditions: ["artifact written"]
      )

    assert blueprint.id == "assistant-test"
    assert [%{path: "tmp/source.md"}] = blueprint.sources
    assert {:ok, report} = BlueprintValidator.validate(blueprint)
    assert report.status == :accepted
  end

  test "rejects duplicate ids, unknown edges, and missing stop conditions" do
    blueprint =
      WorkflowBlueprint.new!(
        "Bad graph",
        [
          ComponentBlueprint.new!("same", :source_splitter),
          ComponentBlueprint.new!("same", :llm_map)
        ],
        edges: [%{from: "missing", to: "same"}],
        stop_conditions: []
      )

    report = BlueprintValidator.report(blueprint)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :duplicate_component_ids))
    assert Enum.any?(report.diagnostics, &(&1.code == :unknown_edge_source))
    assert Enum.any?(report.diagnostics, &(&1.code == :missing_stop_conditions))
  end

  test "rejects generated functions above policy tier" do
    function = FunctionBlueprint.new!(:tier2, source: "fn input -> input end")

    blueprint =
      WorkflowBlueprint.new!(
        "Transform",
        [
          ComponentBlueprint.new!("transform", :blueprint_transform,
            params: %{function: function}
          )
        ],
        stop_conditions: ["transformed"]
      )

    report = BlueprintValidator.report(blueprint, max_generated_function_tier: :tier1)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :function_tier_rejected))
  end

  test "round-trips generated blueprints through JSON-safe maps" do
    blueprint =
      WorkflowBlueprint.new!("Round trip", [ComponentBlueprint.new!("split", "source_splitter")],
        sources: [%{"id" => "chapter", "path" => "tmp/chapter.md"}],
        stop_conditions: ["done"]
      )

    json = Jason.encode!(blueprint)
    decoded = Jason.decode!(json)

    assert {:ok, decoded_blueprint} = WorkflowBlueprint.from_input(decoded)
    assert decoded_blueprint.objective == "Round trip"
    assert hd(decoded_blueprint.components).type == :source_splitter
  end
end
