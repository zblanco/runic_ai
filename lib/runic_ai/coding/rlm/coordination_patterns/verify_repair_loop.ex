defmodule RunicAI.Coding.RLM.CoordinationPatterns.VerifyRepairLoop do
  @moduledoc """
  Generic verification and repair coordination pattern.
  """

  @spec pattern() :: map()
  def pattern do
    %{
      name: :verify_repair_loop,
      loop: [
        :run_acceptance_checks,
        :classify_failures,
        :assign_repair_child,
        :apply_bounded_repair,
        :rerun_failed_checks
      ],
      stop_conditions: [:acceptance_satisfied, :repair_budget_exhausted, :blocked],
      requires_decreasing_measure?: true,
      metadata: %{generic?: true}
    }
  end
end
