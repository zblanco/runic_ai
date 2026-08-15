defmodule RunicAI.Coding.Recipes.WriteTests do
  @moduledoc """
  Test-focused editing and verification recipe.
  """

  alias Runic.Workflow
  alias RunicAI.Coding.Agent
  alias RunicAI.Coding.Recipe

  @spec new(keyword()) :: Recipe.t()
  def new(opts \\ []), do: Recipe.named(:write_tests, opts)

  @spec run(term(), String.t(), keyword()) :: Workflow.t()
  def run(workspace_input, task, opts \\ []) do
    Agent.run(workspace_input, task, Keyword.merge([command: :write_tests], opts))
  end
end
