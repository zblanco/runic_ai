defmodule RunicAI.Runtime.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for runtime session servers.
  """

  use DynamicSupervisor

  alias RunicAI.Runtime.SessionServer
  alias RunicAI.Runtime.SessionSpec

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session(SessionSpec.t()) :: DynamicSupervisor.on_start_child()
  def start_session(%SessionSpec{} = spec) do
    DynamicSupervisor.start_child(__MODULE__, SessionServer.child_spec(spec))
  end
end
