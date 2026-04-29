defmodule RunicAI.Coding.RLM.CoordinationPatterns.ReviewScorecard do
  @moduledoc """
  Generic review and final scorecard coordination pattern.
  """

  @spec pattern() :: map()
  def pattern do
    %{
      name: :review_scorecard,
      inputs: [
        :child_results,
        :verification_observations,
        :acceptance_results,
        :changed_files,
        :repair_history,
        :residual_risks
      ],
      outputs: [:objective_status, :final_report],
      metadata: %{generic?: true}
    }
  end
end
