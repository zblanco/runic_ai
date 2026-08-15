defmodule RunicAI.RLM.SubagentDelegationWorkflowTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.RLM.ContextSlicer
  alias RunicAI.RLM.DelegationAdapters.StandardAgent
  alias RunicAI.RLM.DelegationMapper
  alias RunicAI.RLM.SubagentReducer

  test "maps file-group subagents and reducer surfaces reviewer conflicts" do
    workspace = sample_workspace()

    {:ok, sliced} =
      ContextSlicer.file_set(workspace, ["lib/api.ex", "lib/worker.ex"],
        expected_output_schema: %{required: ["claims", "evidence_refs"]}
      )

    parent = %{
      run_id: "run:parent",
      strategy: :subagent_delegation,
      fallback: :lambda_workflow,
      depth: 1
    }

    assert {:ok, mapped} =
             DelegationMapper.map_slices(sliced.slices,
               id_prefix: "review",
               role: "component reviewer",
               objective_template: "Review {{source_ref}} for execution model claims",
               prompt_template: "Inspect only {{source_ref}} and return claim-shaped output.",
               capability_profile: :coding_read,
               visible_tools: [:read_file],
               budgets: %{max_tool_calls: 2},
               output_schema: %{required: ["claims", "evidence_refs"]},
               parent: parent
             )

    runner = fn _objective, args, _context ->
      claim_for_path(args.context_metadata.path)
    end

    child_results =
      Enum.map(mapped.assignments, fn assignment ->
        assert {:ok, result} =
                 StandardAgent.run(workspace, assignment,
                   runner: runner,
                   session_id: "session:parent"
                 )

        result.child_result
      end)

    assert {:ok, reduced} = SubagentReducer.reduce(child_results)

    assert reduced.status == :review
    assert reduced.claim_count == 2
    assert [%{claim_id: "api-sync", target_claim_id: "worker-async"}] = reduced.conflicts
    assert reduced.summary.conflict_count == 1
    assert reduced.summary.unsupported_count == 0

    roles = Enum.map(reduced.claims, & &1.role) |> Enum.uniq()
    assert roles == ["component reviewer"]

    assert Enum.sort(Enum.map(reduced.claims, & &1.source_slice_id)) ==
             mapped.assignments
             |> Enum.map(& &1.context_slice.id)
             |> Enum.sort()
  end

  defp claim_for_path(source_ref) do
    cond do
      String.contains?(source_ref, "api") ->
        {:ok,
         %{
           status: :completed,
           claims: [
             %{
               id: "api-sync",
               claim: "The execution path is synchronous",
               evidence_refs: ["lib/api.ex:1"],
               conflicts_with: ["worker-async"],
               confidence: 0.72
             }
           ]
         }}

      String.contains?(source_ref, "worker") ->
        {:ok,
         %{
           status: :completed,
           claims: [
             %{
               id: "worker-async",
               claim: "The execution path is asynchronous",
               evidence_refs: ["lib/worker.ex:1"],
               confidence: 0.77
             }
           ]
         }}
    end
  end

  defp sample_workspace do
    root =
      Path.join([
        System.tmp_dir!(),
        "runic-ai-subagent-delegation-workflow-test-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/api.ex"), "defmodule API do\n  def call, do: :ok\nend\n")

    File.write!(
      Path.join(root, "lib/worker.ex"),
      "defmodule Worker do\n  def call, do: Task.async(fn -> :ok end)\nend\n"
    )

    Workspace.new!(root: root)
  end
end
