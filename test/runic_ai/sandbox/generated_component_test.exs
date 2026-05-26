defmodule RunicAI.Sandbox.GeneratedComponentTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Sandbox.GeneratedComponent

  test "validates generated component contracts without atomizing string inputs" do
    assert {:ok, component} =
             GeneratedComponent.new(%{
               "id" => "generated:csv-parser",
               "name" => "CSV parser",
               "language" => "python",
               "runtime" => "python3",
               "entrypoint" => "component.py:parse",
               "source_artifacts" => ["artifact://component.py"],
               "test_artifacts" => [%{ref: "artifact://test_component.py"}],
               "interface" => %{
                 inputs: [%{name: "csv", type: "string"}],
                 outputs: [%{name: "rows", type: "records"}]
               },
               "verification" => %{status: "pass", command: "pytest"},
               "promotion_status" => "verified",
               "capability_profile" => "sandbox_python_read",
               "sandbox_profile" => "docker_python",
               "metadata" => %{"generated_by" => "test"}
             })

    assert component.language == :python
    assert component.promotion_status == :verified
    assert GeneratedComponent.verified?(component)
    assert GeneratedComponent.promotable?(component)
  end

  test "builds a sandbox_execute component blueprint after verification" do
    component =
      GeneratedComponent.new!(
        id: "generated:analyzer",
        name: "Analyzer",
        language: :python,
        runtime: :python,
        entrypoint: "analyzer.py:run",
        source_artifacts: [%{ref: "artifact://analyzer.py", path: "analyzer.py"}],
        test_artifacts: ["artifact://test_analyzer.py"],
        interface: %{inputs: [%{name: "input"}], outputs: [%{name: "output"}]},
        verification: %{status: :pass, tests: 3},
        promotion_status: :verified,
        capability_profile: :sandbox_docker_read,
        sandbox_profile: :local_code,
        provenance: ["trace:event:1"],
        metadata: %{objective: "analyze input"}
      )

    assert {:ok, blueprint} = GeneratedComponent.to_component_blueprint(component)

    assert %ComponentBlueprint{} = blueprint
    assert blueprint.id == "generated:analyzer"
    assert blueprint.type == :sandbox_execute
    assert blueprint.params.generated_component?
    assert blueprint.params.entrypoint == "analyzer.py:run"
    assert blueprint.params.source_artifacts == component.source_artifacts
    assert blueprint.metadata.generated_component_id == "generated:analyzer"
    assert blueprint.provenance == ["trace:event:1"]
  end

  test "rejects promotion before verification and source artifacts exist" do
    component =
      GeneratedComponent.new!(
        id: "generated:draft",
        name: "Draft",
        language: :python,
        runtime: :python,
        entrypoint: "draft.py:run",
        source_artifacts: [],
        verification: %{status: :failed},
        promotion_status: :draft
      )

    refute GeneratedComponent.promotable?(component)

    assert {:error, error} = GeneratedComponent.to_component_blueprint(component)
    assert error.kind == :validation
    assert error.message =~ "must be verified"
    assert error.details.source_artifact_count == 0
  end

  test "rejects invalid enum and artifact shapes" do
    assert {:error, error} =
             GeneratedComponent.new(
               id: "generated:bad",
               name: "Bad",
               language: "ruby",
               runtime: :ruby,
               entrypoint: "bad.rb:run"
             )

    assert error.kind == :validation
    assert error.details.field == :language

    assert {:error, error} =
             GeneratedComponent.new(
               id: "generated:bad-artifact",
               name: "Bad artifact",
               language: :python,
               runtime: :python,
               entrypoint: "bad.py:run",
               source_artifacts: [:not_allowed]
             )

    assert error.kind == :validation
    assert error.details.field == :source_artifacts
  end
end
