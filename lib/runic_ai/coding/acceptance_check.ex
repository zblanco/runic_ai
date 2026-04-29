defmodule RunicAI.Coding.AcceptanceCheck do
  @moduledoc """
  Shared deterministic acceptance check API for coding agents.

  The implementation currently delegates to the RLM reliability substrate while
  exposing a non-RLM namespace for the standard coding agent.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck, as: Impl

  @type t :: Impl.t()
  @type result :: Impl.result()

  defdelegate types(), to: Impl
  defdelegate new(type, opts \\ []), to: Impl
  defdelegate new!(type, opts \\ []), to: Impl
  defdelegate from_input(input), to: Impl
  defdelegate validate(check), to: Impl
  defdelegate result(check, status, message, metadata \\ %{}), to: Impl
  defdelegate passed?(result), to: Impl
  defdelegate blocking_failure?(result), to: Impl
end
