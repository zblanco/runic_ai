defmodule RunicAI.Coding.Recipes.ExplainRepo do
  @moduledoc """
  Read-only named recipe for explaining repository structure or module behavior.
  """

  alias Runic.Workflow
  alias RunicAI.Coding.Agent

  @default_task "Explain the repository structure, important modules, and how the main workflows fit together."

  @spec new(RunicAI.Coding.Workspace.t() | keyword() | map() | Path.t(), keyword()) ::
          Workflow.t()
  def new(workspace_input, opts \\ []) do
    Agent.new(workspace_input, Keyword.merge([command: :explain_repo], opts))
  end

  @spec run(RunicAI.Coding.Workspace.t() | keyword() | map() | Path.t(), String.t(), keyword()) ::
          Workflow.t()
  def run(workspace_input, task \\ @default_task, opts \\ []) do
    Agent.run(workspace_input, task, Keyword.merge([command: :explain_repo], opts))
  end
end
