defmodule RunicAI.RLM.WorkflowDelegationAdapterTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Coding.Workspace
  alias RunicAI.RLM.ContextSlicer
  alias RunicAI.RLM.DelegationAdapters.Workflow
  alias RunicAI.RLM.LambdaPlan
  alias RunicAI.RLM.SubagentAssignment
  alias RunicAI.RLM.SubagentReducer

  test "prepares Lambda workflow assignments as validated child results" do
    workspace = sample_workspace()
    {:ok, sliced} = ContextSlicer.file_set(workspace, ["README.md"])
    [context_slice] = sliced.slices

    assignment =
      SubagentAssignment.new!(
        id: "assignment:lambda",
        role: "lambda planner",
        objective: "Summarize README",
        strategy: :lambda_workflow,
        agent_kind: :workflow,
        context_slice: context_slice,
        capability_profile: :coding_read,
        visible_tools: [],
        budgets: %{max_leaf_calls: 3},
        output_schema: %{required: ["claims", "evidence_refs"]},
        parent: %{
          run_id: "run:parent",
          strategy: :subagent_delegation,
          fallback: :lambda_workflow,
          depth: 1
        }
      )

    assert {:ok, result} = Workflow.run(workspace, assignment, task_kind: :summarization)

    assert result.workflow_result.kind == :lambda_plan
    assert %LambdaPlan{} = result.workflow_result.lambda_plan

    operators = LambdaPlan.operator_names(result.workflow_result.lambda_plan)
    assert [:split, :map, :reduce] -- operators == []
    assert result.workflow_result.metadata.operators == operators
    assert result.workflow_result.lambda_plan.fallback_strategy == :subagent_delegation

    assert result.child_result.task_id == "assignment:lambda"
    assert result.child_result.status == :completed

    assert %{claims: [%{claim: summary, evidence_refs: refs}]} = result.child_result.output
    assert summary == "Lambda workflow plan prepared for assignment:lambda"
    assert refs == [context_slice.source_ref.source_id]

    assert {:ok, reduced} = SubagentReducer.reduce([result.child_result])
    assert reduced.status == :accepted
  end

  test "runs generated-component assignments through injected workflow runners" do
    parent = self()
    workspace = sample_workspace()
    {:ok, sliced} = ContextSlicer.file_set(workspace, ["README.md"])
    [context_slice] = sliced.slices

    assignment =
      SubagentAssignment.new!(
        id: "assignment:component",
        role: "component builder",
        objective: "Build a README analyzer component",
        strategy: :generated_sandbox_component,
        agent_kind: :workflow,
        context_slice: context_slice,
        capability_profile: :sandbox_docker_read,
        visible_tools: [:sandbox_execute],
        budgets: %{max_sandbox_executions: 2},
        output_schema: %{required: ["claims", "evidence_refs"]},
        parent: %{
          run_id: "run:parent",
          strategy: :lambda_workflow,
          fallback: :host_edit_workflow,
          depth: 2
        }
      )

    runner = fn runner_assignment, context, opts ->
      send(parent, {:runner_called, runner_assignment, context, opts})

      {:ok,
       %{
         status: :completed,
         kind: :generated_component_build,
         claims: [
           %{
             claim: "component verified",
             evidence_refs: ["artifact://component-test"],
             confidence: 0.9
           }
         ],
         artifact_refs: ["artifact://component-test"]
       }}
    end

    assert {:ok, result} = Workflow.run(workspace, assignment, runner: runner)

    assert_receive {:runner_called, ^assignment, context, opts}
    assert context.workspace == workspace
    assert context.context_slice == context_slice
    assert context.capability_profile == :sandbox_docker_read
    assert context.visible_tools == ["sandbox_execute"]
    assert context.budgets == %{max_sandbox_executions: 2}
    assert Keyword.fetch!(opts, :runner) == runner

    assert result.workflow_result.kind == :generated_component_build
    assert result.child_result.status == :completed

    assert %{claims: [%{claim: "component verified", evidence_refs: refs, confidence: 0.9}]} =
             result.child_result.output

    assert refs == ["artifact://component-test"]
  end

  test "runs coordinator component-builder assignments through workflow adapter" do
    workspace = sample_workspace()
    {:ok, sliced} = ContextSlicer.file_set(workspace, ["README.md"])
    [context_slice] = sliced.slices

    assert {:ok, assignment} =
             Coordinator.component_builder_assignment(
               workspace,
               "Build a README analyzer component",
               id: "assignment:coordinator-component",
               context_slice: context_slice,
               max_sandbox_executions: 2
             )

    runner = fn runner_assignment, context, _opts ->
      assert runner_assignment.id == "assignment:coordinator-component"
      assert context.context_slice == context_slice
      assert context.visible_tools == assignment.visible_tools

      {:ok,
       %{
         status: :completed,
         kind: :generated_component_build,
         claims: [
           %{
             claim: "component builder assignment consumed",
             evidence_refs: ["artifact://component-builder"],
             confidence: 0.8,
             reviewer_notes: ["assignment stayed sandbox-scoped"]
           }
         ],
         artifact_refs: ["artifact://component-builder"]
       }}
    end

    assert {:ok, result} = Workflow.run(workspace, assignment, runner: runner)

    assert result.workflow_result.kind == :generated_component_build

    assert result.child_result.output.claims == [
             %{
               claim: "component builder assignment consumed",
               evidence_refs: ["artifact://component-builder"],
               confidence: 0.8,
               reviewer_notes: ["assignment stayed sandbox-scoped"]
             }
           ]
  end

  test "rejects non-workflow assignments" do
    workspace = sample_workspace()

    assignment =
      SubagentAssignment.new!(
        role: "reader",
        objective: "Inspect README",
        strategy: :subagent_delegation,
        agent_kind: :standard,
        visible_tools: [:read_file],
        output_schema: %{}
      )

    assert {:error, error} = Workflow.run(workspace, assignment)
    assert error.kind == :validation
    assert error.message =~ "workflow assignment strategy"
  end

  test "requires a runner or blueprint for generated-component workflows" do
    workspace = sample_workspace()

    assignment =
      SubagentAssignment.new!(
        role: "component builder",
        objective: "Build a component",
        strategy: :generated_sandbox_component,
        agent_kind: :workflow,
        visible_tools: [:sandbox_execute],
        output_schema: %{}
      )

    assert {:error, error} = Workflow.run(workspace, assignment)
    assert error.kind == :validation
    assert error.message =~ "requires a runner or workflow blueprint"
  end

  defp sample_workspace do
    root =
      Path.join([
        System.tmp_dir!(),
        "runic-ai-workflow-delegation-adapter-test-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "# Sample\n\nhello\n")
    Workspace.new!(root: root)
  end
end
