defmodule RunicAI.Coding.Recipes.FixCI do
  @moduledoc """
  Command-output-driven repair recipe for failing CI or local checks.
  """

  alias Runic.Workflow
  alias RunicAI.Coding.Agent
  alias RunicAI.Coding.Recipe

  @spec new(keyword()) :: Recipe.t()
  def new(opts \\ []), do: Recipe.named(:fix_ci, opts)

  @spec run(term(), String.t(), keyword()) :: Workflow.t()
  def run(workspace_input, task, opts \\ []) do
    Agent.run(workspace_input, task, Keyword.merge([command: :fix_ci], opts))
  end
end
