defmodule RunicAI.Coding.ObjectiveScorecard do
  @moduledoc """
  Shared objective scorecard API for coding agents.
  """

  alias RunicAI.Coding.RLM.WorkflowScorecard, as: Impl

  @type t :: Impl.t()
  @type objective_status :: Impl.objective_status()

  defdelegate statuses(), to: Impl
  defdelegate new(opts \\ []), to: Impl
  defdelegate new!(opts \\ []), to: Impl
  defdelegate from_inputs(opts), to: Impl
  defdelegate objective_satisfied?(input), to: Impl
  defdelegate derive_status(acceptance_results, child_results, command_statuses), to: Impl
  defdelegate current_acceptance_results(acceptance_results), to: Impl
  defdelegate blocking_acceptance_results(acceptance_results), to: Impl
  defdelegate validate(scorecard), to: Impl
end
