defmodule RunicAI.RLM.ContextSlicerTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.RLM.ContextSlicer
  alias RunicAI.RLM.ContextSliceContract
  alias RunicAI.RLM.SubagentAssignment

  test "file_set builds code context contracts without copying full text by default" do
    root = tmp_dir()
    File.write!(Path.join(root, "alpha.ex"), "defmodule Alpha do\n  def one, do: 1\nend\n")
    workspace = Workspace.new!(root: root)

    assert {:ok, result} =
             ContextSlicer.file_set(workspace, ["alpha.ex"],
               strategy: :lines,
               max_bytes: 80,
               expected_output_schema: %{required: ["claims", "evidence_refs"]}
             )

    assert result.family == :file_set
    assert result.count >= 1

    [slice | _] = result.slices
    assert %ContextSliceContract{} = slice
    assert slice.source_kind == :code
    assert slice.expected_output_schema == %{required: ["claims", "evidence_refs"]}
    assert slice.metadata.path == "alpha.ex"
    assert slice.metadata.source_family == :file_set
    refute Map.has_key?(slice.metadata, :preview)
    assert [%{path: "alpha.ex", line_span: [_start, _finish]} | _] = slice.provenance
  end

  test "repo_areas expands shallow directories and records the selected area" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "lib/a"))
    File.write!(Path.join(root, "lib/a/one.ex"), "defmodule One do\nend\n")
    File.write!(Path.join(root, "lib/a/two.ex"), "defmodule Two do\nend\n")
    workspace = Workspace.new!(root: root)

    assert {:ok, result} =
             ContextSlicer.repo_areas(workspace, ["lib/a"],
               strategy: :paragraph,
               max_directory_files: 4
             )

    assert result.family == :repo_area
    assert result.source_count == 2
    assert Enum.map(result.slices, & &1.metadata.repo_area) == ["lib/a", "lib/a"]
    assert Enum.all?(result.slices, &(&1.source_kind == :code))
  end

  test "document_sections turns markdown headings into document slice contracts" do
    markdown = """
    # Overview
    First section.

    ## Risks
    Second section.
    """

    assert {:ok, result} =
             ContextSlicer.document_sections([%{id: "doc-1", text: markdown}],
               strategy: :markdown_heading,
               preview_bytes: 12
             )

    assert result.family == :document_section
    assert Enum.map(result.slices, & &1.metadata.section_label) == ["Overview", "Risks"]

    [overview | _] = result.slices
    assert overview.source_kind == :document
    assert overview.metadata.document_id == "doc-1"
    assert overview.metadata.preview =~ "# Overview"

    assert [%{document_id: "doc-1", label: "Overview", line_span: [1, 3]}] =
             overview.provenance
  end

  test "artifact_partitions groups artifact refs by kind" do
    artifacts = [
      %{ref: "artifact://one", kind: :report, path: ".docs/one.md"},
      %{ref: "artifact://two", kind: :trace, path: ".runic/trace.jsonl"},
      "artifact://three"
    ]

    assert {:ok, result} = ContextSlicer.artifact_partitions(artifacts, group_by: :kind)

    assert result.family == :artifact_partition
    assert result.count == 3

    groups = result.slices |> Enum.map(& &1.metadata.artifact_group) |> Enum.sort()
    assert groups == ["artifact", "report", "trace"]
    assert Enum.all?(result.slices, &(&1.source_kind == :artifact))
  end

  test "review_roles creates role-specific structured slices over existing context slices" do
    root = tmp_dir()
    File.write!(Path.join(root, "alpha.ex"), "defmodule Alpha do\nend\n")
    workspace = Workspace.new!(root: root)

    {:ok, source_result} = ContextSlicer.file_set(workspace, ["alpha.ex"])
    [source_slice | _] = source_result.slices

    assert {:ok, result} =
             ContextSlicer.review_roles(
               [
                 %{
                   id: "coverage",
                   name: "coverage reviewer",
                   output_schema: %{required: ["gaps"]}
                 },
                 :security
               ],
               [source_slice],
               token_budget: 1_000
             )

    assert result.family == :review_role
    assert result.count == 2

    [coverage, security] = result.slices
    assert coverage.source_kind == :structured
    assert coverage.expected_output_schema == %{required: ["gaps"]}
    assert coverage.review_policy.role == "coverage reviewer"
    assert coverage.token_budget == 1_000
    assert hd(coverage.provenance).id == source_slice.id

    assert security.review_policy.role == "security"

    assignment =
      SubagentAssignment.new!(
        role: "coverage reviewer",
        objective: "Review one source slice for gaps",
        strategy: :subagent_delegation,
        context_slice: coverage,
        visible_tools: [:read_file],
        budgets: %{max_tool_calls: 3},
        output_schema: coverage.expected_output_schema,
        parent: %{
          run_id: "run:parent",
          strategy: :subagent_delegation,
          fallback: :lambda_workflow,
          depth: 1
        }
      )

    assert assignment.context_slice.id == coverage.id
    assert assignment.visible_tools == ["read_file"]
  end

  test "slicers return RunicAI errors for invalid contract options" do
    root = tmp_dir()
    File.write!(Path.join(root, "alpha.ex"), "defmodule Alpha do\nend\n")
    workspace = Workspace.new!(root: root)

    assert {:error, error} = ContextSlicer.file_set(workspace, ["alpha.ex"], token_budget: 0)
    assert error.kind in [:unexpected, :validation]
    assert error.message =~ "token_budget"
  end

  defp tmp_dir do
    Path.join([
      System.tmp_dir!(),
      "runic-ai-context-slicer-test-#{System.unique_integer([:positive])}"
    ])
    |> tap(&File.mkdir_p!/1)
  end
end
