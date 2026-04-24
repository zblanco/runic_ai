defmodule RunicAI.Harness.Driver do
  @moduledoc """
  Behaviour shared by the process-agnostic harness drivers.
  """

  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session

  @callback new_session(module(), keyword()) :: Session.t()
  @callback submit(Session.t(), term()) :: Session.t()
  @callback advance(Session.t(), Policy.t() | keyword() | nil) :: Session.t()
  @callback drain(Session.t(), Policy.t() | keyword() | nil) :: Session.t()
  @callback snapshot(Session.t()) :: term()
  @callback outputs(Session.t()) :: list()
end
