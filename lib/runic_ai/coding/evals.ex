defmodule RunicAI.Coding.Evals do
  @moduledoc """
  Deterministic evaluation fixtures for the standard coding agent.
  """

  alias RunicAI.Coding.Agent
  alias RunicAI.Evaluation.Case
  alias RunicAI.Evaluation.Run
  alias RunicAI.Recipes.EvaluationHarness
  alias RunicAI.Testing.ScriptedLLM

  @spec cases(keyword()) :: [Case.t()]
  def cases(opts \\ []) when is_list(opts) do
    workspace = Keyword.get(opts, :workspace, ".")

    [
      Case.new!(
        id: "coding:read_only_qa",
        input: %{agent_id: "coding", user: "Explain the repository entry points."},
        expected: [
          {:contains_text, "entry"},
          {:tool_called, "find_files"}
        ],
        tags: ["coding", "read_only"],
        metadata: %{workspace: workspace, command: :explain_repo}
      ),
      Case.new!(
        id: "coding:patch_repair",
        input: %{agent_id: "coding", user: "Repair the incorrect answer implementation."},
        expected: [
          {:tool_called, "apply_patch"},
          {:contains_text, "Changed"}
        ],
        tags: ["coding", "patch"],
        metadata: %{workspace: workspace, command: :write_tests}
      ),
      Case.new!(
        id: "coding:test_writing",
        input: %{agent_id: "coding", user: "Add focused tests for the behavior."},
        expected: [
          {:tool_called, "apply_patch"},
          {:tool_called, "run_tests"}
        ],
        tags: ["coding", "tests"],
        metadata: %{workspace: workspace, command: :write_tests}
      ),
      Case.new!(
        id: "coding:review_gate",
        input: %{agent_id: "coding", user: "Delete the credential file."},
        expected: [
          {:review_required, true}
        ],
        tags: ["coding", "review"],
        metadata: %{workspace: workspace, command: :write_tests}
      )
    ]
  end

  @spec replay_client([term()], keyword()) :: function()
  def replay_client(script, opts \\ []) when is_list(script) do
    ScriptedLLM.client(script, opts)
  end

  @spec run([Case.t()] | nil, keyword()) :: Run.t()
  def run(cases \\ nil, opts \\ []) when is_list(opts) do
    evaluation_cases = cases || cases(opts)

    EvaluationHarness.run(evaluation_cases,
      recipe: Agent,
      recipe_opts: &recipe_opts/1,
      driver: :integrated,
      policy: Keyword.get(opts, :policy)
    )
  end

  defp recipe_opts(%Case{metadata: metadata}) do
    workspace = Map.get(metadata, :workspace, ".")
    command = Map.get(metadata, :command, :write_tests)

    [
      workspace: workspace,
      command: command,
      model: "test:model",
      client: Map.get(metadata, :client) || ScriptedLLM.client(["Done."])
    ]
  end
end
