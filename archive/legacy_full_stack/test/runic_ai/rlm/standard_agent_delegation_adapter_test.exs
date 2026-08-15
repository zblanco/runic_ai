defmodule RunicAI.RLM.StandardAgentDelegationAdapterTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.RLM.ContextSlicer
  alias RunicAI.RLM.DelegationAdapters.StandardAgent
  alias RunicAI.RLM.SubagentAssignment
  alias RunicAI.RLM.SubagentReducer

  test "runs assignments through delegate_task with constrained standard-agent args" do
    parent = self()
    workspace = sample_workspace()
    {:ok, sliced} = ContextSlicer.file_set(workspace, ["README.md"])
    [context_slice] = sliced.slices

    assignment =
      SubagentAssignment.new!(
        id: "assignment:readme",
        role: "reader",
        objective: "Inspect README",
        strategy: :subagent_delegation,
        agent_kind: :standard,
        context_slice: context_slice,
        capability_profile: :coding_read,
        visible_tools: [:read_file, "find_files"],
        output_schema: %{required: ["claims", "evidence_refs"]},
        parent: %{
          run_id: "run:parent",
          strategy: :subagent_delegation,
          fallback: :lambda_workflow,
          depth: 1
        }
      )

    runner = fn objective, args, context ->
      send(parent, {:runner_called, objective, args, context})

      {:ok,
       %{
         summary: "README says hello",
         source_refs: [args.context_source_ref],
         artifact_refs: []
       }}
    end

    assert {:ok, result} =
             StandardAgent.run(workspace, assignment,
               runner: runner,
               session_id: "session:parent"
             )

    assert_receive {:runner_called, "Inspect README", args, context}
    assert args.agent_kind == "standard"
    assert args.profile == "coding_read"
    assert args.visible_tools == ["read_file", "find_files"]
    assert args.context_slice_id == context_slice.id
    assert args.parent_depth == 1
    assert context.workspace == workspace
    assert context.profile == "coding_read"

    assert result.delegate_result.summary == "README says hello"
    assert result.child_result.task_id == "assignment:readme"
    assert result.child_result.status == :completed

    assert %{claims: [%{claim: "README says hello", evidence_refs: refs}]} =
             result.child_result.output

    assert refs == [context_slice.source_ref.source_id]

    assert {:ok, reduced} = SubagentReducer.reduce([result.child_result])
    assert reduced.status == :accepted
  end

  test "rejects non-standard assignment kinds" do
    workspace = sample_workspace()

    assignment =
      SubagentAssignment.new!(
        role: "lambda worker",
        objective: "Run a workflow",
        strategy: :lambda_workflow,
        agent_kind: :workflow,
        visible_tools: [],
        output_schema: %{}
      )

    assert {:error, error} =
             StandardAgent.run(workspace, assignment, runner: fn _, _, _ -> %{} end)

    assert error.kind == :validation
    assert error.message =~ "agent_kind :standard"
  end

  test "maps failed delegate responses to failed child results" do
    workspace = sample_workspace()

    assignment =
      SubagentAssignment.new!(
        id: "assignment:failed",
        role: "reader",
        objective: "Inspect README",
        strategy: :subagent_delegation,
        agent_kind: :standard,
        visible_tools: [:read_file],
        output_schema: %{}
      )

    runner = fn _objective, _args, _context ->
      {:ok, %{status: :failed, summary: "child failed"}}
    end

    assert {:ok, result} = StandardAgent.run(workspace, assignment, runner: runner)
    assert result.child_result.status == :failed
    assert result.child_result.metadata.delegate_status == :failed
  end

  defp sample_workspace do
    root =
      Path.join([
        System.tmp_dir!(),
        "runic-ai-standard-delegation-adapter-test-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "hello\n")
    Workspace.new!(root: root)
  end
end
