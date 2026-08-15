defmodule RunicAI.Workbench.WorkflowRunner do
  @moduledoc """
  Owns the SQLite-backed Runic runner used by durable Workbench workflows.

  The StoreServer starts first, so this supervisor can give the runner the same
  store used by definition, review, event, and projection APIs.
  """

  use Supervisor

  alias RunicAI.Persistence.RunnerStore
  alias RunicAI.Workbench.StoreServer

  @supervisor_name RunicAI.Workbench.WorkflowRunnerSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: @supervisor_name)
  end

  @spec runner() :: module()
  def runner, do: __MODULE__

  @impl true
  def init(_opts) do
    store = StoreServer.store!()

    Supervisor.init(
      [
        {Runic.Runner, name: __MODULE__, store: RunnerStore, store_opts: [store: store]}
      ],
      strategy: :one_for_one
    )
  end
end
