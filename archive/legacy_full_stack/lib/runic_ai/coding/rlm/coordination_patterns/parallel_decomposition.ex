defmodule RunicAI.Coding.RLM.CoordinationPatterns.ParallelDecomposition do
  @moduledoc """
  Generic dynamic fan-out/fan-in coordination pattern.
  """

  @spec pattern() :: map()
  def pattern do
    %{
      name: :parallel_decomposition,
      coordinator_responsibilities: [
        :choose_child_roles,
        :assign_narrow_scopes,
        :declare_dependencies,
        :define_fan_in_gates,
        :merge_child_artifacts
      ],
      forbidden_shortcuts: [:language_specific_template, :framework_specific_template],
      requires_dynamic_nodes?: true,
      metadata: %{generic?: true}
    }
  end
end
