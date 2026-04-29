defmodule RunicAI.Coding.RLM.RecipeLibrary do
  @moduledoc """
  Seed workflow patterns for high-confidence RLM coding routes.
  """

  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.WorkflowProposal

  @recipes [:repo_qa, :bug_investigation, :patch_planning, :review, :verify]

  @spec names() :: [atom()]
  def names, do: @recipes

  @spec proposal(atom() | String.t(), String.t(), keyword()) :: WorkflowProposal.t()
  def proposal(recipe, objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    recipe
    |> normalize_recipe()
    |> build(objective, opts)
  end

  @spec summaries() :: [map()]
  def summaries do
    Enum.map(@recipes, fn recipe ->
      %{
        name: recipe,
        description: description(recipe),
        mutates?: recipe in [:patch_planning, :verify],
        node_kinds: recipe_node_kinds(recipe)
      }
    end)
  end

  defp build(:repo_qa, objective, opts) do
    WorkflowProposal.new!(
      objective,
      [
        ProposalNode.new!("discover", :tool,
          params: %{tool: "find_files", args: %{path: ".", query: Keyword.get(opts, :query, "")}}
        ),
        ProposalNode.new!("read", :tool,
          params: %{tool: "read_many", args: %{paths: Keyword.get(opts, :paths, [])}}
        ),
        ProposalNode.new!("answer", :reducer, params: %{reducer: "report"})
      ],
      edges: [%{from: "discover", to: "read"}, %{from: "read", to: "answer"}],
      sources: Keyword.get(opts, :sources, []),
      expected_artifacts: [:report],
      stop_conditions: ["answer cites inspected files"],
      metadata: %{recipe: :repo_qa}
    )
  end

  defp build(:bug_investigation, objective, opts) do
    WorkflowProposal.new!(
      objective,
      [
        ProposalNode.new!("manifest", :deterministic_step, params: %{action: "source_summary"}),
        ProposalNode.new!("search", :tool,
          params: %{tool: "search_text", args: %{query: Keyword.get(opts, :query, "fail")}}
        ),
        ProposalNode.new!("diagnose", :reducer, params: %{reducer: "findings"})
      ],
      edges: [%{from: "manifest", to: "search"}, %{from: "search", to: "diagnose"}],
      sources: Keyword.get(opts, :sources, []),
      expected_artifacts: [:finding],
      stop_conditions: ["ranked diagnosis produced"],
      metadata: %{recipe: :bug_investigation}
    )
  end

  defp build(:patch_planning, objective, opts) do
    WorkflowProposal.new!(
      objective,
      [
        ProposalNode.new!("inspect", :agent, params: %{mode: "read_only", task: objective}),
        ProposalNode.new!("plan", :reducer, params: %{reducer: "patch_plan"})
      ],
      edges: [%{from: "inspect", to: "plan"}],
      sources: Keyword.get(opts, :sources, []),
      expected_artifacts: [:patch_plan],
      stop_conditions: ["patch plan includes verification strategy"],
      metadata: %{recipe: :patch_planning}
    )
  end

  defp build(:review, objective, opts) do
    WorkflowProposal.new!(
      objective,
      [
        ProposalNode.new!("diff", :tool, params: %{tool: "git_diff", args: %{}}),
        ProposalNode.new!("review", :reducer, params: %{reducer: "findings"})
      ],
      edges: [%{from: "diff", to: "review"}],
      sources: Keyword.get(opts, :sources, []),
      expected_artifacts: [:finding, :risk],
      stop_conditions: ["review findings ranked by severity"],
      metadata: %{recipe: :review}
    )
  end

  defp build(:verify, objective, opts) do
    WorkflowProposal.new!(
      objective,
      [
        ProposalNode.new!("verify", :agent, params: %{mode: "verify", task: objective}),
        ProposalNode.new!("summarize", :reducer, params: %{reducer: "verification"})
      ],
      edges: [%{from: "verify", to: "summarize"}],
      sources: Keyword.get(opts, :sources, []),
      expected_artifacts: [:verification_observation],
      stop_conditions: ["verification status summarized"],
      metadata: %{recipe: :verify}
    )
  end

  defp normalize_recipe(recipe) when recipe in @recipes, do: recipe
  defp normalize_recipe("repo_qa"), do: :repo_qa
  defp normalize_recipe("bug_investigation"), do: :bug_investigation
  defp normalize_recipe("patch_planning"), do: :patch_planning
  defp normalize_recipe("review"), do: :review
  defp normalize_recipe("verify"), do: :verify
  defp normalize_recipe(_recipe), do: :repo_qa

  defp description(:repo_qa), do: "Read-only repository question answering."
  defp description(:bug_investigation), do: "Read/search/log investigation without edits."

  defp description(:patch_planning),
    do: "Read-only patch plan with edit and verification strategy."

  defp description(:review), do: "Diff-focused review with ranked findings."
  defp description(:verify), do: "Narrow standard-agent verify child workflow."

  defp recipe_node_kinds(recipe) do
    recipe
    |> proposal("example")
    |> Map.fetch!(:nodes)
    |> Enum.map(& &1.kind)
  end
end
