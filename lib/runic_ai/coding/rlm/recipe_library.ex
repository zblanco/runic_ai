defmodule RunicAI.Coding.RLM.RecipeLibrary do
  @moduledoc """
  Seed workflow patterns for high-confidence RLM coding routes.
  """

  alias RunicAI.Coding.RLM.ElixirProjectGenerator
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.WorkflowProposal

  @recipes [
    :repo_qa,
    :bug_investigation,
    :patch_planning,
    :review,
    :verify,
    :project_generation,
    :progress_observability
  ]

  @spec names() :: [atom()]
  def names, do: @recipes

  @spec proposal(atom() | String.t(), String.t(), keyword()) :: WorkflowProposal.t()
  def proposal(recipe, objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    recipe
    |> normalize_recipe()
    |> build(objective, opts)
  end

  @spec summaries(keyword()) :: [map()]
  def summaries(opts \\ []) do
    opts
    |> visible_recipes()
    |> Enum.map(fn recipe ->
      %{
        name: recipe,
        description: description(recipe),
        mutates?: recipe in [:patch_planning, :verify, :project_generation],
        node_kinds: recipe_node_kinds(recipe)
      }
    end)
  end

  defp visible_recipes(opts) do
    if Keyword.get(opts, :project_generation?, false) do
      @recipes
    else
      Enum.reject(@recipes, &(&1 == :project_generation))
    end
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

  defp build(:project_generation, objective, opts) do
    objective_contract = objective_contract(objective, opts)
    contract_map = ObjectiveContract.to_map(objective_contract)

    compile_args =
      ElixirProjectGenerator.command_args(objective, :compile,
        objective_contract: objective_contract
      )

    test_args =
      ElixirProjectGenerator.command_args(objective, :test,
        objective_contract: objective_contract
      )

    runtime_smoke_args =
      ElixirProjectGenerator.command_args(objective, :runtime_smoke,
        objective_contract: objective_contract
      )

    WorkflowProposal.new!(
      objective,
      [
        ProposalNode.new!("acceptance_contract", :deterministic_step,
          params: %{
            action: "constant",
            value:
              Map.merge(contract_map, %{
                evidence_required: [
                  "changed source paths",
                  "objective-specific tests",
                  "compile/test/runtime-smoke evidence",
                  "residual risks when blocked"
                ],
                non_goals: [
                  "repository summary as final output",
                  "scaffold-only tests",
                  "claims of verification without command or runtime evidence"
                ]
              })
          }
        ),
        ProposalNode.new!("implement_project", :edit,
          params: %{
            patch_set:
              ElixirProjectGenerator.patch_set(objective,
                sources: Keyword.get(opts, :sources, []),
                objective_contract: objective_contract
              )
          }
        ),
        ProposalNode.new!("compile_project", :command,
          params: %{
            args: %{
              argv: Map.fetch!(compile_args, :argv),
              cwd: Map.get(compile_args, :cwd, "."),
              timeout_ms: 120_000,
              metadata: %{
                safe?: true,
                requires_review?: false,
                risk: :low,
                purpose: :compile_verification
              }
            }
          }
        ),
        ProposalNode.new!("test_project", :command,
          params: %{
            args: %{
              argv: Map.fetch!(test_args, :argv),
              cwd: Map.get(test_args, :cwd, "."),
              timeout_ms: 120_000,
              metadata: %{
                safe?: true,
                requires_review?: false,
                risk: :low,
                purpose: :test_verification
              }
            }
          }
        ),
        ProposalNode.new!("runtime_smoke", :command,
          params: %{
            args: %{
              argv: Map.fetch!(runtime_smoke_args, :argv),
              cwd: Map.get(runtime_smoke_args, :cwd, "."),
              timeout_ms: 120_000,
              metadata: %{
                safe?: true,
                requires_review?: false,
                risk: :low,
                purpose: :runtime_smoke
              }
            }
          }
        ),
        ProposalNode.new!("verify_project", :verification_gate,
          params: %{
            checks:
              ElixirProjectGenerator.verification_checks(objective,
                objective_contract: objective_contract
              )
          }
        ),
        ProposalNode.new!("summarize_evidence", :reducer, params: %{reducer: "verification"})
      ],
      edges: [
        %{from: "acceptance_contract", to: "implement_project"},
        %{from: "implement_project", to: "compile_project"},
        %{from: "compile_project", to: "test_project"},
        %{from: "test_project", to: "runtime_smoke"},
        %{from: "runtime_smoke", to: "verify_project"},
        %{from: "verify_project", to: "summarize_evidence"}
      ],
      sources: Keyword.get(opts, :sources, []),
      expected_artifacts: [
        :source_implementation,
        :tests,
        :verification_evidence,
        :changed_file_inventory
      ],
      stop_conditions: [
        "objective-specific source and tests exist",
        "verification gate reports acceptance evidence or explicit blockers",
        "final evidence summary cites changed paths and verification status"
      ],
      metadata:
        %{recipe: :project_generation, seeded?: true}
        |> Map.put(:objective_contract, contract_map)
    )
  end

  defp build(:progress_observability, objective, opts) do
    objective_contract =
      ObjectiveContract.new!(objective,
        requirements: [
          %{
            id: "progress_ticks",
            kind: "verification",
            description: "Emit visible runtime progress ticks before final completion.",
            required: true,
            evidence_needed: ["command_result", "ui_progress_event"],
            acceptance_criteria: [
              "command output includes rlm_progress_tick values",
              "browser Plan tab captures active progress before final completion"
            ]
          }
        ],
        metadata: %{
          source: :progress_observability_recipe,
          evidence_required: ["command_result", "active_progress_snapshot"]
        }
      )

    WorkflowProposal.new!(
      objective,
      [
        ProposalNode.new!("acceptance_contract", :deterministic_step,
          params: %{
            action: "constant",
            value: ObjectiveContract.to_map(objective_contract)
          }
        ),
        ProposalNode.new!("stream_progress", :command,
          params: %{
            args: %{
              argv: [
                "elixir",
                "-e",
                "for i <- 1..5 do IO.puts(\"rlm_progress_tick=\#{i}\"); Process.sleep(500); end"
              ],
              timeout_ms: 10_000,
              metadata: %{safe?: true, risk: :low, purpose: :progress_observability}
            }
          }
        ),
        ProposalNode.new!("summarize_progress", :reducer, params: %{reducer: "verification"})
      ],
      edges: [
        %{from: "acceptance_contract", to: "stream_progress"},
        %{from: "stream_progress", to: "summarize_progress"}
      ],
      sources: Keyword.get(opts, :sources, []),
      expected_artifacts: [:runtime_progress_evidence],
      stop_conditions: ["progress ticks are visible before final completion"],
      metadata: %{
        recipe: :progress_observability,
        observability_probe?: true,
        objective_contract: ObjectiveContract.to_map(objective_contract)
      }
    )
  end

  defp objective_contract(objective, opts) do
    case Keyword.get(opts, :objective_contract) do
      %ObjectiveContract{} = contract ->
        contract

      contract when is_map(contract) or is_list(contract) ->
        ObjectiveContract.from_input(contract) |> unwrap_contract(objective, opts)

      _other ->
        ObjectiveContract.infer!(objective)
    end
  end

  defp unwrap_contract({:ok, %ObjectiveContract{} = contract}, _objective, _opts), do: contract

  defp unwrap_contract({:error, _error}, objective, _opts),
    do: ObjectiveContract.infer!(objective)

  defp normalize_recipe(recipe) when recipe in @recipes, do: recipe
  defp normalize_recipe("repo_qa"), do: :repo_qa
  defp normalize_recipe("bug_investigation"), do: :bug_investigation
  defp normalize_recipe("patch_planning"), do: :patch_planning
  defp normalize_recipe("review"), do: :review
  defp normalize_recipe("verify"), do: :verify
  defp normalize_recipe("project_generation"), do: :project_generation
  defp normalize_recipe("progress_observability"), do: :progress_observability
  defp normalize_recipe(_recipe), do: :repo_qa

  defp description(:repo_qa), do: "Read-only repository question answering."
  defp description(:bug_investigation), do: "Read/search/log investigation without edits."

  defp description(:patch_planning),
    do: "Read-only patch plan with edit and verification strategy."

  defp description(:review), do: "Diff-focused review with ranked findings."
  defp description(:verify), do: "Narrow standard-agent verify child workflow."

  defp description(:project_generation),
    do:
      "Generic project-generation workflow with implementation, verification, and evidence stages."

  defp description(:progress_observability),
    do: "Bounded runtime progress probe for Workbench/browser observability."

  defp recipe_node_kinds(recipe) do
    recipe
    |> proposal("example")
    |> Map.fetch!(:nodes)
    |> Enum.map(& &1.kind)
  end
end
