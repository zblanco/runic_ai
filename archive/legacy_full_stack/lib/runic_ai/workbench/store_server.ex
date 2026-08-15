defmodule RunicAI.Workbench.StoreServer do
  @moduledoc """
  Owns the local SQLite store used by the Phoenix workbench.

  The store remains a normal `RunicAI.Persistence.SQLite.Store`; this process
  gives web code one supervised place to retrieve it without making LiveViews
  own database processes.
  """

  use GenServer

  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @spec store(GenServer.server()) :: {:ok, Store.t()} | {:error, term()}
  def store(server \\ @name), do: GenServer.call(server, :store)

  @spec store!(GenServer.server()) :: Store.t()
  def store!(server \\ @name) do
    case store(server) do
      {:ok, %Store{} = store} -> store
      {:error, reason} -> raise "RunicAI workbench store unavailable: #{inspect(reason)}"
    end
  end

  @spec health(GenServer.server()) :: map()
  def health(server \\ @name), do: GenServer.call(server, :health)

  @impl true
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:runic_ai, :workbench, []), opts)
    sqlite_opts = sqlite_opts(opts)

    case SQLite.open(sqlite_opts) do
      {:ok, %Store{} = store} ->
        {:ok, %{store: store, opts: opts}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:store, _from, %{store: %Store{} = store} = state) do
    {:reply, {:ok, store}, state}
  end

  def handle_call(:health, _from, %{store: %Store{} = store, opts: opts} = state) do
    health = %{
      database: store.database,
      data_path: Keyword.get(opts, :data_path),
      migrated?: migrated?(store),
      available?: SQLite.available?()
    }

    {:reply, health, state}
  end

  @impl true
  def terminate(_reason, %{store: %Store{} = store}) do
    SQLite.close(store)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp sqlite_opts(opts) do
    [
      database: Keyword.get(opts, :database, default_database(opts)),
      migrate?: Keyword.get(opts, :migrate?, true),
      metadata: %{surface: :phoenix_workbench}
    ]
  end

  defp default_database(opts) do
    opts
    |> Keyword.get(:data_path, Path.expand(".runic_ai"))
    |> Path.expand()
    |> Path.join("runs.db")
  end

  defp migrated?(%Store{} = store) do
    match?({:ok, version} when version > 0, SQLite.schema_version(store))
  end
end
