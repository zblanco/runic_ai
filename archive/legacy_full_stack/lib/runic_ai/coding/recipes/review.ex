defmodule RunicAI.Coding.Recipes.Review do
  @moduledoc """
  Diff-focused, read-only coding-agent recipe.
  """

  alias Runic.Workflow
  alias RunicAI.Coding.Agent
  alias RunicAI.Coding.Recipe

  @spec new(keyword()) :: Recipe.t()
  def new(opts \\ []), do: Recipe.named(:review, opts)

  @spec run(term(), String.t(), keyword()) :: Workflow.t()
  def run(workspace_input, task, opts \\ []) do
    Agent.run(workspace_input, task, Keyword.merge([command: :review], opts))
  end
end
