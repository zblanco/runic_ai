defmodule RunicAI.Coding.Persistence.ETS do
  @moduledoc """
  ETS-backed coding persistence store for development and integration tests.

  This adapter mirrors `RunicAI.Coding.Persistence.InMemory` while using ETS as
  the storage substrate. It is process-local to the BEAM VM, supports cheap
  inspection from tests, and matches the same persistence behaviour used by the
  coding harness.
  """

  @behaviour RunicAI.Coding.Persistence

  alias RunicAI.Coding.Patch

  @type handle :: %{
          required(:artifacts_table) => atom(),
          required(:events_table) => atom(),
          required(:counter_table) => atom()
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)

    Agent.start_link(fn -> new_handle(opts) end, Keyword.take([name: name], [:name]))
  end

  @spec handle(pid()) :: handle()
  def handle(agent) when is_pid(agent), do: Agent.get(agent, & &1)

  @impl true
  def put_artifact(agent, artifact) when is_pid(agent) and is_map(artifact) do
    put_artifact(handle(agent), artifact)
  end

  def put_artifact(%{artifacts_table: table}, artifact) when is_map(artifact) do
    ref =
      "ets:" <>
        (Map.get(artifact, :sha256) ||
           Map.get(artifact, "sha256") ||
           Patch.sha256(inspect(artifact)))

    stored =
      artifact
      |> Map.put_new(:artifact_ref, ref)
      |> Map.put_new(:stored_at, DateTime.utc_now())

    :ets.insert(table, {ref, stored})

    {:ok, ref}
  end

  @impl true
  def get_artifact(agent, ref) when is_pid(agent) and is_binary(ref) do
    get_artifact(handle(agent), ref)
  end

  def get_artifact(%{artifacts_table: table}, ref) when is_binary(ref) do
    case :ets.lookup(table, ref) do
      [{^ref, artifact}] -> {:ok, artifact}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def record_event(agent, event) when is_pid(agent) and is_map(event) do
    record_event(handle(agent), event)
  end

  def record_event(%{events_table: events_table, counter_table: counter_table}, event)
      when is_map(event) do
    sequence = :ets.update_counter(counter_table, :events, {2, 1}, {:events, 0})
    stored = Map.put_new(event, :recorded_at, DateTime.utc_now())

    :ets.insert(events_table, {sequence, stored})

    :ok
  end

  @spec artifacts(pid() | handle()) :: [map()]
  def artifacts(agent) when is_pid(agent), do: artifacts(handle(agent))

  def artifacts(%{artifacts_table: table}) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_ref, artifact} -> artifact end)
    |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :stored_at)))
  end

  @spec events(pid() | handle()) :: [map()]
  def events(agent) when is_pid(agent), do: events(handle(agent))

  def events(%{events_table: table}) do
    table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {sequence, _event} -> sequence end)
    |> Enum.map(fn {_sequence, event} -> event end)
  end

  defp new_handle(opts) do
    suffix = Keyword.get(opts, :name) || System.unique_integer([:positive])

    artifacts_table = table_name(suffix, "Artifacts")
    events_table = table_name(suffix, "Events")
    counter_table = table_name(suffix, "Counters")

    :ets.new(artifacts_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(events_table, [:named_table, :ordered_set, :public, read_concurrency: true])

    :ets.new(counter_table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    %{
      artifacts_table: artifacts_table,
      events_table: events_table,
      counter_table: counter_table
    }
  end

  defp table_name(suffix, kind) when is_atom(suffix), do: Module.concat([suffix, kind])

  defp table_name(suffix, kind) do
    Module.concat([RunicAI.Coding.Persistence.ETS, :"Store#{suffix}", kind])
  end

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_datetime), do: 0
end
