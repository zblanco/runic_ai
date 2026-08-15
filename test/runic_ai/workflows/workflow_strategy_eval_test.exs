defmodule RunicAI.Workflows.WorkflowStrategyEvalTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.RunicAi.WorkflowStrategyEval

  test "batch artifact proof accepts explicit IDs and markdown table rows" do
    root =
      Path.join(
        System.tmp_dir!(),
        "workflow-strategy-eval-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    explicit_path = Path.join(root, "explicit.md")

    File.write!(
      explicit_path,
      "# Queue\n\n## Normalized Work Items\n\nid=1\nid=2\nid=3\nid=4\n"
    )

    table_path = Path.join(root, "table.md")

    ownership_path = Path.join(root, "ownership.md")

    File.write!(
      ownership_path,
      "## Ownership Index\n\nteam=api work_item=1\nteam=web work-item: 2\nteam=api work item 3\nteam=ops work_item=4\n"
    )

    File.write!(
      table_path,
      """
      ## Normalized Work Items

      | ID | Team | Status |
      | --- | --- | --- |
      | `1` | api | ready |
      | `2` | web | blocked |
      | `3` | api | ready |
      | `4` | ops | review |
      """
    )

    assert :ok =
             WorkflowStrategyEval.verify_batch_artifact(explicit_path, [
               "Normalized Work Items"
             ])

    assert :ok =
             WorkflowStrategyEval.verify_batch_artifact(table_path, ["Normalized Work Items"])

    assert :ok =
             WorkflowStrategyEval.verify_batch_artifact(ownership_path, ["Ownership Index"])

    assert {:error, :artifact_content_incomplete} =
             WorkflowStrategyEval.verify_batch_artifact(table_path, ["Missing Section"])
  end
end
