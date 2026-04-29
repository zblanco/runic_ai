defmodule RunicAI.Coding.Persistence.InMemory do
  @moduledoc """
  In-memory coding persistence store for development and tests.

  The store keeps artifacts and trace-like events in an Agent. It is deliberately
  simple and process-local, which makes it a good default while the durable
  SQLite implementation remains optional.
  """

  @behaviour RunicAI.Coding.Persistence

  alias RunicAI.Coding.Patch

  @type state :: %{
          artifacts: %{optional(String.t()) => map()},
          events: [map()]
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{artifacts: %{}, events: []} end, Keyword.take(opts, [:name]))
  end

  @impl true
  def put_artifact(agent, artifact) when is_pid(agent) and is_map(artifact) do
    ref =
      "mem:" <>
        (Map.get(artifact, :sha256) ||
           Map.get(artifact, "sha256") ||
           Patch.sha256(inspect(artifact)))

    stored =
      artifact
      |> Map.put_new(:artifact_ref, ref)
      |> Map.put_new(:stored_at, DateTime.utc_now())

    Agent.update(agent, fn state ->
      put_in(state, [:artifacts, ref], stored)
    end)

    {:ok, ref}
  end

  @impl true
  def get_artifact(agent, ref) when is_pid(agent) and is_binary(ref) do
    case Agent.get(agent, &Map.get(&1.artifacts, ref)) do
      nil -> {:error, :not_found}
      artifact -> {:ok, artifact}
    end
  end

  @impl true
  def record_event(agent, event) when is_pid(agent) and is_map(event) do
    stored = Map.put_new(event, :recorded_at, DateTime.utc_now())

    Agent.update(agent, fn state ->
      update_in(state.events, &[stored | &1])
    end)
  end

  @spec artifacts(pid()) :: [map()]
  def artifacts(agent) when is_pid(agent) do
    Agent.get(agent, fn state ->
      state.artifacts
      |> Map.values()
      |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :stored_at)))
    end)
  end

  @spec events(pid()) :: [map()]
  def events(agent) when is_pid(agent) do
    Agent.get(agent, fn state -> Enum.reverse(state.events) end)
  end

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_datetime), do: 0
end
