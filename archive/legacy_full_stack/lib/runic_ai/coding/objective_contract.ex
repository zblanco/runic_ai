defmodule RunicAI.Coding.ObjectiveContract do
  @moduledoc """
  Shared semantic objective contract API for coding agents.
  """

  alias RunicAI.Coding.RLM.ObjectiveContract, as: Impl

  @type t :: Impl.t()

  defdelegate new(objective, opts \\ []), to: Impl
  defdelegate new!(objective, opts \\ []), to: Impl
  defdelegate from_input(input), to: Impl
  defdelegate validate(contract), to: Impl
  defdelegate ensure(objective, context, opts \\ []), to: Impl
  defdelegate extract(objective, opts \\ []), to: Impl
  defdelegate schema(), to: Impl
  defdelegate zoi_schema(), to: Impl
  defdelegate prompt(objective, opts \\ []), to: Impl
end
