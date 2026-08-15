defmodule RunicAI.RLM.SubagentAssignmentTest do
  use ExUnit.Case, async: true

  alias RunicAI.RLM.ContextSliceContract
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.SubagentAssignment

  test "builds constrained assignments with context slices tools budgets and parent metadata" do
    source_ref =
      EnvironmentRef.new!(RunicAI.RLM.SubagentAssignmentTest, "file-group-a",
        metadata: %{source_kind: :code}
      )

    context_slice =
      ContextSliceContract.new!(source_ref,
        slice_id: "lib/runic_ai/rlm",
        source_kind: :code,
        byte_budget: 12_000,
        expected_output_schema: %{required: ["claims", "evidence_refs"]},
        review_policy: %{requires_evidence?: true}
      )

    assert {:ok, assignment} =
             SubagentAssignment.new(%{
               "id" => "assign:file-group-a",
               "role" => "codebase_reviewer",
               "objective" => "Inspect RLM modules for delegation seams",
               "prompt" => "Return claims with file references only.",
               "strategy" => "subagent_delegation",
               "agent_kind" => "standard",
               "context_slice" => context_slice,
               "capability_profile" => "coding_read",
               "visible_tools" => ["read_file", :find_files],
               "budgets" => %{"max_tool_calls" => 8, "max_tokens" => 12_000},
               "output_schema" => %{"required" => ["claims", "evidence_refs"]},
               "review_policy" => %{"reviewer" => "sandbox_reviewer"},
               "parent" => %{
                 "run_id" => "run:parent",
                 "strategy" => "subagent_delegation",
                 "depth" => 1,
                 "fallback" => "lambda_workflow",
                 "remaining_budgets" => %{"max_subagents" => 3}
               },
               "metadata" => %{"slice_reason" => "file group"}
             })

    assert assignment.id == "assign:file-group-a"
    assert assignment.strategy == :subagent_delegation
    assert assignment.agent_kind == :standard
    assert assignment.context_slice.source_kind == :code
    assert assignment.visible_tools == ["read_file", "find_files"]
    assert assignment.parent.strategy == :subagent_delegation
    assert assignment.parent.fallback == :lambda_workflow
    assert assignment.parent.depth == 1
    assert assignment.parent.remaining_budgets == %{"max_subagents" => 3}
  end

  test "defaults workflow agent kind for workflow-shaped nested strategies" do
    assignment =
      SubagentAssignment.new!(
        role: "lambda_mapper",
        objective: "Extract risks from one source bundle",
        strategy: "lambda_workflow",
        visible_tools: [],
        budgets: %{max_leaf_calls: 4},
        output_schema: %{required: ["records"]}
      )

    assert assignment.agent_kind == :workflow
    assert assignment.parent == nil
  end

  test "rejects invalid strategies tools budgets and parent depth without atomizing strings" do
    assert {:error, error} =
             SubagentAssignment.new(
               role: "reviewer",
               objective: "Review one slice",
               strategy: "unknown_strategy"
             )

    assert error.kind == :validation
    assert error.details.strategy == "unknown_strategy"

    assert {:error, error} =
             SubagentAssignment.new(
               role: "reviewer",
               objective: "Review one slice",
               visible_tools: ["read_file", 123]
             )

    assert error.kind == :validation
    assert error.details.visible_tools == ["read_file", 123]

    assert {:error, error} =
             SubagentAssignment.new(
               role: "reviewer",
               objective: "Review one slice",
               budgets: [max_calls: 1]
             )

    assert error.kind == :validation
    assert error.details.budgets == [max_calls: 1]

    assert {:error, error} =
             SubagentAssignment.new(
               role: "reviewer",
               objective: "Review one slice",
               parent: %{
                 run_id: "run:parent",
                 strategy: :subagent_delegation,
                 fallback: :lambda_workflow,
                 depth: -1
               }
             )

    assert error.kind == :validation
    assert error.details.field == :parent_depth
  end
end
