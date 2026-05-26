defmodule RunicAI.Sandbox.GeneratedComponentWorkflowTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Assistant.RLM.WorkflowCompiler
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.ReviewDecision
  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentWorkflow

  test "composes a verified generated component into an accepted sandbox workflow" do
    component = generated_component()

    assert {:ok, blueprint} =
             GeneratedComponentWorkflow.compose("Parse CSV rows", component,
               id: "generated-component:csv-workflow",
               profile: :local_workbench,
               toolsets: [:code_execution],
               scorecard_params: %{acceptance: ["rows returned"]}
             )

    assert %WorkflowBlueprint{} = blueprint
    assert blueprint.id == "generated-component:csv-workflow"
    assert blueprint.metadata.proposal_kind == :generated_component_composition
    assert blueprint.metadata.generated_component_ids == ["generated:csv-parser"]
    assert blueprint.policies.generated_components.require_verified?
    assert blueprint.policies.sandbox.network == :disabled

    assert [execute, scorecard] = blueprint.components
    assert execute.type == :sandbox_execute
    assert execute.id == "generated:csv-parser"
    assert execute.inputs == ["csv"]
    assert execute.outputs == ["rows"]
    assert execute.policy.sandbox.network == :disabled
    assert execute.params.generated_component?
    assert execute.params.entrypoint == "parser.py:run"
    assert execute.params.interface == component.interface
    assert execute.metadata.generated_component_id == "generated:csv-parser"

    assert scorecard.type == :objective_scorecard
    assert scorecard.params.acceptance == ["rows returned"]
    assert blueprint.edges == [%{from: "generated:csv-parser", to: "verify_generated_components"}]

    assert BlueprintValidator.report(blueprint,
             profile: :local_workbench,
             toolsets: [:code_execution]
           ).status == :accepted
  end

  test "rejects unverified generated components before blueprint composition" do
    component = %{
      generated_component()
      | promotion_status: :draft,
        verification: %{status: :failed}
    }

    assert {:error, error} =
             GeneratedComponentWorkflow.compose("Parse CSV rows", component,
               profile: :local_workbench,
               toolsets: [:code_execution]
             )

    assert error.kind == :validation
    assert error.message =~ "must be verified"
    assert error.details.id == "generated:csv-parser"
  end

  test "supports chained composition of multiple generated components" do
    parser = generated_component()
    normalizer = generated_component(id: "generated:normalizer", name: "Normalizer")

    assert {:ok, blueprint} =
             GeneratedComponentWorkflow.compose("Parse and normalize rows", [parser, normalizer],
               profile: :local_workbench,
               toolsets: [:code_execution],
               component_ids: %{"generated:normalizer" => "normalize_rows"}
             )

    assert Enum.map(blueprint.components, & &1.id) == [
             "generated:csv-parser",
             "normalize_rows",
             "verify_generated_components"
           ]

    assert blueprint.edges == [
             %{from: "generated:csv-parser", to: "normalize_rows"},
             %{from: "normalize_rows", to: "verify_generated_components"}
           ]
  end

  test "coordinator can return a generated-component workflow without LLM proposal" do
    workspace = Workspace.new!(root: tmp_dir())

    client = fn _model, _prompt, _opts ->
      flunk("generated component composition should not call blueprint proposal client")
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Parse CSV rows",
               generated_component: generated_component(),
               profile: :local_workbench,
               toolsets: [:code_execution],
               client: client
             )

    assert blueprint.metadata.proposal_kind == :generated_component_composition
    assert Enum.map(blueprint.components, & &1.type) == [:sandbox_execute, :objective_scorecard]
  end

  test "compiled workflow executes generated component metadata through sandbox arguments only" do
    workspace = Workspace.new!(root: tmp_dir())

    assert {:ok, blueprint} =
             GeneratedComponentWorkflow.compose("Parse CSV rows", generated_component(),
               profile: :local_workbench,
               toolsets: [:code_execution],
               component_params: %{
                 runtime: :bash,
                 code:
                   "printf '{\"rows\":[{\"name\":\"apple\",\"qty\":2}],\"format\":\"csv\"}\\n'",
                 max_output_bytes: 2_048
               }
             )

    review_decider = fn request, _context ->
      assert request.details.tool_name == "execute_code"
      {:ok, ReviewDecision.new!(request.resume_key, :approved)}
    end

    assert {:ok, result} =
             WorkflowCompiler.run(blueprint, workspace, %{},
               profile: :local_workbench,
               toolsets: [:code_execution],
               review_decider: review_decider
             )

    component_result = Enum.find(result.component_results, &(&1.id == "generated:csv-parser"))

    assert result.scorecard.objective_status in [:objective_satisfied, :objective_incomplete]
    assert component_result.output.output =~ ~s("rows")
  end

  test "composition honors capability-profile rejection" do
    assert {:error, error} =
             GeneratedComponentWorkflow.compose("Parse CSV rows", generated_component(),
               profile: :local_workbench,
               toolsets: [:code_execution],
               disabled_tools: ["execute_code"]
             )

    assert error.kind == :validation
    assert get_in(error.details, [:report, :status]) == :rejected
  end

  defp generated_component(overrides \\ []) do
    defaults = [
      id: "generated:csv-parser",
      name: "CSV parser",
      language: :python,
      runtime: :python,
      entrypoint: "parser.py:run",
      source_artifacts: [%{ref: "artifact://parser.py", path: "parser.py"}],
      test_artifacts: [%{ref: "artifact://test_parser.py", path: "test_parser.py"}],
      interface: %{
        inputs: [%{name: "csv", type: "string"}],
        outputs: [%{name: "rows", type: "records"}]
      },
      verification: %{status: :pass, command: "pytest -q"},
      promotion_status: :verified,
      capability_profile: :sandbox_python_read,
      sandbox_profile: :local_code,
      metadata: %{domain: "tabular"}
    ]

    defaults
    |> Keyword.merge(overrides)
    |> GeneratedComponent.new!()
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-generated-component-workflow-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
