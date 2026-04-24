defmodule RunicAI.Runtime.Backends.InMemory do
  @moduledoc """
  Runtime backend that delegates directly to the selected harness driver.
  """

  @behaviour RunicAI.Runtime.Backend

  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session
  alias RunicAI.Runtime.SessionSpec

  defstruct [:spec, :session, metadata: %{}]

  @type t :: %__MODULE__{spec: SessionSpec.t(), session: Session.t(), metadata: map()}

  @impl true
  def init(%SessionSpec{} = spec) do
    session =
      spec.driver.new_session(spec.recipe,
        id: spec.id,
        recipe_opts: spec.recipe_opts,
        policy: spec.policy,
        metadata: spec.metadata
      )

    {:ok, %__MODULE__{spec: spec, session: session, metadata: %{backend: :in_memory}}}
  end

  @impl true
  def submit(%__MODULE__{session: session, spec: spec} = state, input) do
    {:ok, %{state | session: spec.driver.submit(session, input)}}
  end

  @impl true
  def advance(%__MODULE__{session: session, spec: spec} = state, %Policy{} = policy) do
    {:ok, %{state | session: spec.driver.advance(session, policy)}}
  end

  @impl true
  def drain(%__MODULE__{session: session, spec: spec} = state, %Policy{} = policy) do
    {:ok, %{state | session: spec.driver.drain(session, policy)}}
  end

  @impl true
  def session(%__MODULE__{session: session}), do: session

  @impl true
  def snapshot(%__MODULE__{session: session}), do: session.snapshot

  @impl true
  def outputs(%__MODULE__{session: session}), do: session.outputs

  @impl true
  def trajectory(%__MODULE__{session: session}), do: session.trajectory

  @impl true
  def shutdown(%__MODULE__{}), do: :ok
end
