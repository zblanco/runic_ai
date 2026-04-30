defmodule RunicAI.Assistant.RLM.RepairLoop do
  @moduledoc """
  Minimal repair loop for assistant workflow blueprints.

  The first repair strategy is intentionally conservative: when a generated or
  caller-supplied blueprint is invalid, fall back to the generic coordinator
  graph and record the repair episode.
  """

  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @spec fallback_repair(Workspace.t(), String.t(), Error.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def fallback_repair(%Workspace{} = workspace, objective, %Error{} = error, opts \\ []) do
    with {:ok, blueprint} <-
           Coordinator.fallback_blueprint(workspace, objective, Keyword.delete(opts, :blueprint)) do
      {:ok,
       %{
         status: :repaired,
         strategy: :generic_fallback_blueprint,
         reason: error.message,
         blueprint: blueprint
       }}
    end
  end
end
