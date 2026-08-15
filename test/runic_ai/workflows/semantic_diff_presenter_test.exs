defmodule RunicAI.Workflows.SemanticDiffPresenterTest do
  use ExUnit.Case, async: true

  alias RunicAI.Workflows.SemanticDiffPresenter

  test "renders typed operations as operator-facing semantic changes" do
    projection =
      SemanticDiffPresenter.present(%{
        operations: [
          %{op: "set_policy", key: "max_runtime_ms", value: 120_000},
          %{op: "set_argument", node_id: "verify", key: "max_items", value: 4},
          %{
            op: "connect",
            from: %{node: "research", port: "findings"},
            to: %{node: "verify", port: "items"}
          },
          %{
            op: "set_acceptance",
            acceptance_id: "verified",
            check: %{description: "Every finding has a verdict", required: true}
          }
        ]
      })

    assert projection.summary == "4 semantic changes"

    assert Enum.map(projection.changes, & &1.title) == [
             "Set workflow policy max runtime ms",
             "Change verify max items",
             "Connect research.findings to verify.items",
             "Set acceptance verified"
           ]

    assert List.last(projection.changes).detail == "Every finding has a verdict."
  end

  test "falls back to a human-readable revision diff when operations are unavailable" do
    projection =
      SemanticDiffPresenter.present(%{
        diff: %{
          nodes: %{added: ["verify"], removed: [], changed: ["write"]},
          edges: %{added: ["research:verify"], removed: ["research:write"], changed: []},
          acceptance: %{added: [], removed: [], changed: []},
          holes: %{added: [], removed: [], changed: []},
          workflow_policy: %{
            changed?: true,
            before: %{max_runtime_ms: 60_000},
            after: %{max_runtime_ms: 120_000}
          },
          workflow_metadata: %{changed?: false, before: %{}, after: %{}}
        }
      })

    assert projection.summary == "5 semantic changes"
    assert Enum.any?(projection.changes, &(&1.title == "Node added" and &1.detail == "verify"))
    assert Enum.any?(projection.changes, &(&1.title == "Workflow policy changed"))
  end
end
