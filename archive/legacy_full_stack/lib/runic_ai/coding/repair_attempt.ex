defmodule RunicAI.Coding.RepairAttempt do
  @moduledoc """
  Shared repair-attempt evidence API for coding agents.
  """

  alias RunicAI.Coding.RLM.RepairAttempt, as: Impl

  @type t :: Impl.t()
  @type status :: Impl.status()

  defdelegate new(opts), to: Impl
  defdelegate new!(opts), to: Impl
  defdelegate validate(attempt), to: Impl
end
