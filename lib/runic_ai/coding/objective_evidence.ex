defmodule RunicAI.Coding.ObjectiveEvidence do
  @moduledoc """
  Shared compact evidence gathering API for coding objective judgement.
  """

  alias RunicAI.Coding.RLM.ObjectiveEvidence, as: Impl

  defdelegate gather(workspace, context, opts \\ []), to: Impl
  defdelegate summary(evidence), to: Impl
end
