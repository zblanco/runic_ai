defmodule RunicAI.Coding.RLM.CoordinationPatterns.StagedDelivery do
  @moduledoc """
  Generic staged-delivery coordination pattern.

  This is not a task template. It names the coordination stages the RLM
  coordinator should dynamically instantiate with task-specific nodes.
  """

  @spec pattern() :: map()
  def pattern do
    %{
      name: :staged_delivery,
      stages: [
        :understand_objective,
        :derive_acceptance_contract,
        :inspect_workspace,
        :plan_work,
        :execute_bounded_changes,
        :verify,
        :repair_or_report
      ],
      requires_dynamic_nodes?: true,
      metadata: %{generic?: true}
    }
  end
end
