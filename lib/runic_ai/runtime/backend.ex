defmodule RunicAI.Runtime.Backend do
  @moduledoc """
  Behaviour for runtime backends that carry a canonical harness session.
  """

  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session
  alias RunicAI.Runtime.SessionSpec
  alias RunicAI.Trace.Trajectory

  @type state :: term()

  @callback init(SessionSpec.t()) :: {:ok, state()} | {:error, term()}
  @callback submit(state(), term()) :: {:ok, state()} | {:error, term()}
  @callback advance(state(), Policy.t()) :: {:ok, state()} | {:error, term()}
  @callback drain(state(), Policy.t()) :: {:ok, state()} | {:error, term()}
  @callback session(state()) :: Session.t()
  @callback snapshot(state()) :: term()
  @callback outputs(state()) :: list()
  @callback trajectory(state()) :: Trajectory.t()
  @callback shutdown(state()) :: :ok | {:error, term()}
end
