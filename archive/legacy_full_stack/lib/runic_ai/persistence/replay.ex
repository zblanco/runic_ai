defmodule RunicAI.Persistence.Replay do
  @moduledoc """
  Offline replay and timeline helpers for durable RunicAI runs.
  """

  alias Runic.Workflow
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.RunnerStore
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Schemas.TerminalEvent

  @spec events(Store.t(), term()) :: {:ok, [struct()]} | {:error, term()}
  def events(%Store{} = store, workflow_id) do
    with {:ok, stream} <- RunnerStore.stream(workflow_id, store) do
      {:ok, Enum.to_list(stream)}
    end
  end

  @spec log(Store.t(), term()) :: {:ok, [struct()]} | {:error, term()}
  def log(%Store{} = store, workflow_id), do: RunnerStore.load(workflow_id, store)

  @spec workflow(Store.t(), term(), keyword()) :: {:ok, Workflow.t()} | {:error, term()}
  def workflow(%Store{} = store, workflow_id, opts \\ []) do
    with {:ok, events} <- log(store, workflow_id) do
      fact_mode = Keyword.get(opts, :fact_mode, :full)

      workflow =
        if fact_mode == :full do
          Workflow.from_events(events)
        else
          Workflow.from_events(events, nil, fact_mode: fact_mode)
        end

      {:ok, workflow}
    end
  end

  @spec terminal_events(Store.t(), String.t()) :: [TerminalEvent.t()]
  def terminal_events(%Store{} = store, run_id), do: Queries.run_timeline(store, run_id)

  @spec compact_terminal_timeline(Store.t(), String.t()) :: [map()]
  def compact_terminal_timeline(%Store{} = store, run_id) do
    store
    |> terminal_events(run_id)
    |> Enum.map(&compact_terminal_event/1)
  end

  defp compact_terminal_event(%TerminalEvent{} = event) do
    %{
      sequence: event.sequence,
      at: event.at,
      agent: event.agent,
      kind: event.kind,
      phase: event.phase,
      status: event.status,
      title: event.title,
      detail: event.detail
    }
  end
end
