defmodule RunicAI.Coding.AcceptanceContract do
  @moduledoc """
  Shared objective-level acceptance contract API for coding agents.
  """

  alias RunicAI.Coding.RLM.AcceptanceContract, as: Impl

  @type t :: Impl.t()

  defdelegate new(objective, opts \\ []), to: Impl
  defdelegate new!(objective, opts \\ []), to: Impl
  defdelegate draft(objective, opts \\ []), to: Impl
  defdelegate from_input(input), to: Impl
  defdelegate validate(contract), to: Impl
  defdelegate evaluate(contract, workspace, context \\ %{}), to: Impl
  defdelegate status(results), to: Impl
end
