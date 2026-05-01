defmodule RunicAI.Assistant.RLM.Smoke do
  @moduledoc """
  Manual smoke scenario catalog for dynamic assistant workflow generation.
  """

  @spec scenarios() :: [map()]
  def scenarios do
    Enum.map(RunicAI.Assistant.RLM.SmokeScenario.all(), fn scenario ->
      %{
        id: scenario.id,
        objective: scenario.objective,
        inputs: scenario.inputs,
        output: scenario.output,
        required_sections: scenario.required_sections,
        source_cues: scenario.source_cues,
        capability_pressure: scenario.expected_workflow_capabilities
      }
    end)
  end
end
