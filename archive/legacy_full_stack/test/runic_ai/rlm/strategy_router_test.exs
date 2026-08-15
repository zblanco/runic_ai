defmodule RunicAI.RLM.StrategyRouterTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.RLM.StrategyRouter

  test "routes known large-context extraction to lambda workflow" do
    decision =
      StrategyRouter.route("Extract risks from these sections and write a report",
        input_paths: ["a.md", "b.md", "c.md"]
      )

    assert decision.strategy == :lambda_workflow
    assert :known_split_map_reduce_shape in decision.reasons
    assert decision.budgets.max_leaf_calls >= 9
    assert decision.fallback == :subagent_delegation
  end

  test "routes partitionable investigations to subagent delegation" do
    decision =
      StrategyRouter.route("Delegate by file group and reconcile reviewer findings",
        input_paths: Enum.map(1..12, &"lib/file_#{&1}.ex")
      )

    assert decision.strategy == :subagent_delegation
    assert :partitionable_context in decision.reasons
    assert decision.budgets.max_subagents == 8
  end

  test "routes unknown artifacts to sandbox repl" do
    decision =
      StrategyRouter.route("Explore this unknown schema and probe the data interactively",
        exploratory?: true
      )

    assert decision.strategy == :sandbox_repl
    assert decision.budgets.max_turns == 8
    assert decision.fallback == :subagent_delegation
  end

  test "routes repeated parsers and scorers to generated sandbox components" do
    decision =
      StrategyRouter.route("Build a reusable parser component for these CSV exports",
        repeated_transform?: true
      )

    assert decision.strategy == :generated_sandbox_component
    assert decision.budgets.require_tests?
    assert decision.fallback == :sandbox_repl
  end

  test "routes narrow local edits to host edit workflow or direct agent" do
    edit =
      StrategyRouter.route("Fix the failing test in this file", input_paths: ["test/demo.exs"])

    assert edit.strategy == :host_edit_workflow

    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    direct =
      StrategyRouter.route("Tell me what this README says", workspace, input_paths: ["README.md"])

    assert direct.strategy == :direct_standard_agent
    assert direct.metadata.workspace_root == root
    assert direct.metadata.deterministic?
  end

  test "metadata is trace-friendly" do
    decision = StrategyRouter.route("Summarize a report", input_paths: ["a.md", "b.md", "c.md"])
    metadata = StrategyRouter.metadata(decision)

    assert metadata.strategy == :lambda_workflow
    assert metadata.router == StrategyRouter
    assert %DateTime{} = metadata.routed_at
    assert metadata.budgets == decision.budgets
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-strategy-router-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
