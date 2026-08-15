defmodule RunicAI.RLM.DelegationMapperTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.RLM.ContextSlicer
  alias RunicAI.RLM.DelegationMapper
  alias RunicAI.RLM.SubagentAssignment

  test "fans out context slices into constrained subagent assignments" do
    root = tmp_dir()
    File.write!(Path.join(root, "a.ex"), "defmodule A do\nend\n")
    File.write!(Path.join(root, "b.ex"), "defmodule B do\nend\n")
    workspace = Workspace.new!(root: root)

    {:ok, sliced} = ContextSlicer.file_set(workspace, ["a.ex", "b.ex"], byte_budget: 4_000)

    assert {:ok, mapped} =
             DelegationMapper.map_slices(sliced.slices,
               id_prefix: "inspect",
               role: "code reviewer",
               objective_template: "Inspect {{slice_id}} from {{source_kind}}",
               prompt_template: "Use evidence from {{source_ref}} only.",
               strategy: "subagent_delegation",
               visible_tools: [:read_file, "find_files"],
               capability_profile: :coding_read,
               budgets: %{max_tool_calls: 4},
               output_schema: %{required: ["claims", "evidence_refs"]},
               parent: %{
                 run_id: "run:parent",
                 strategy: :subagent_delegation,
                 fallback: :lambda_workflow,
                 depth: 1,
                 remaining_budgets: %{max_subagents: 4}
               }
             )

    assert mapped.strategy == :subagent_delegation
    assert mapped.count == 2

    assert [%SubagentAssignment{} = first | _] = mapped.assignments
    assert first.id =~ "inspect:1:"
    assert first.role == "code reviewer"
    assert first.objective =~ "Inspect"
    assert first.objective =~ "from code"
    assert first.prompt =~ "Use evidence from file_set:"
    assert first.visible_tools == ["read_file", "find_files"]
    assert first.capability_profile == :coding_read
    assert first.budgets.max_tool_calls == 4
    assert first.budgets.context_byte_budget == 4_000
    assert first.output_schema == %{required: ["claims", "evidence_refs"]}
    assert first.parent.depth == 1
  end

  test "uses review-role metadata as assignment role when present" do
    root = tmp_dir()
    File.write!(Path.join(root, "a.ex"), "defmodule A do\nend\n")
    workspace = Workspace.new!(root: root)

    {:ok, sliced} = ContextSlicer.file_set(workspace, ["a.ex"])

    {:ok, review_slices} =
      ContextSlicer.review_roles(
        [%{id: "security", name: "security reviewer", output_schema: %{required: ["risks"]}}],
        sliced.slices
      )

    assert {:ok, mapped} =
             DelegationMapper.map_slices(review_slices.slices,
               role: "fallback role",
               objective_template: "{{role}} review for {{slice_id}}",
               visible_tools: [:read_file]
             )

    [assignment] = mapped.assignments
    assert assignment.role == "security reviewer"
    assert assignment.objective =~ "security reviewer review"
    assert assignment.output_schema == %{required: ["risks"]}
    assert assignment.review_policy.role == "security reviewer"
  end

  test "rejects missing templates and invalid strategies" do
    assert {:error, error} = DelegationMapper.map_slices([], role: "reviewer")
    assert error.kind == :validation
    assert error.details.field == :objective_template

    assert {:error, error} =
             DelegationMapper.map_slices([],
               role: "reviewer",
               objective_template: "Review",
               strategy: "not_a_strategy"
             )

    assert error.kind == :validation
    assert error.details.strategy == "not_a_strategy"
  end

  defp tmp_dir do
    Path.join([
      System.tmp_dir!(),
      "runic-ai-delegation-mapper-test-#{System.unique_integer([:positive])}"
    ])
    |> tap(&File.mkdir_p!/1)
  end
end
