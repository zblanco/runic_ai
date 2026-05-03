defmodule RunicAI.Persistence.Export do
  @moduledoc """
  Portable exports derived from the durable SQLite read model.
  """

  alias RunicAI.Persistence.JSON
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Schemas.TerminalEvent

  @spec terminal_jsonl(Store.t(), String.t()) :: String.t()
  def terminal_jsonl(%Store{} = store, run_id) when is_binary(run_id) do
    store
    |> Queries.run_timeline(run_id)
    |> Enum.map_join("", fn event ->
      event
      |> terminal_event_map()
      |> Jason.encode!()
      |> Kernel.<>("\n")
    end)
  end

  @spec write_terminal_jsonl(Store.t(), String.t(), Path.t()) :: :ok | {:error, term()}
  def write_terminal_jsonl(%Store{} = store, run_id, path)
      when is_binary(run_id) and is_binary(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write(path, terminal_jsonl(store, run_id))
  end

  defp terminal_event_map(%TerminalEvent{} = event) do
    %{
      id: event.id,
      at: DateTime.to_iso8601(event.at),
      session_id: event.session_id,
      run_id: event.run_id,
      sequence: event.sequence,
      agent: event.agent,
      kind: event.kind,
      phase: event.phase,
      status: event.status,
      title: event.title,
      detail: event.detail,
      data: JSON.safe(event.data_json)
    }
  end
end
