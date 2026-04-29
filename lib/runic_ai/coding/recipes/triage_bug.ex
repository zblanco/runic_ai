defmodule RunicAI.Coding.Recipes.TriageBug do
  @moduledoc """
  Read/search/git investigation recipe for bug reports.
  """

  alias Runic.Workflow
  alias RunicAI.Coding.Agent
  alias RunicAI.Coding.Recipe

  @spec new(keyword()) :: Recipe.t()
  def new(opts \\ []), do: Recipe.named(:triage_bug, opts)

  @spec run(term(), String.t(), keyword()) :: Workflow.t()
  def run(workspace_input, task, opts \\ []) do
    Agent.run(workspace_input, task, Keyword.merge([command: :triage_bug], opts))
  end
end
