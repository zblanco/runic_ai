defmodule RunicAI.Coding.ObjectiveJudge do
  @moduledoc """
  Shared semantic objective judge API for coding agents.
  """

  alias RunicAI.Coding.RLM.ObjectiveJudge, as: Impl

  @type requirement_result :: Impl.requirement_result()

  defdelegate evaluate(contract, evidence, opts \\ []), to: Impl
  defdelegate acceptance_results(contract, judgement), to: Impl
  defdelegate schema(), to: Impl
  defdelegate zoi_schema(), to: Impl
  defdelegate prompt(contract, evidence), to: Impl
end
