defmodule RunicAI.Persistence.SQLite do
  @moduledoc """
  Ecto SQLite-backed persistence store for local RunicAI harness durability.
  """

  @behaviour RunicAI.Persistence.Store

  import Ecto.Query

  alias RunicAI.Coding.Patch
  alias RunicAI.Error
  alias RunicAI.Persistence
  alias RunicAI.Persistence.HarnessProjection
  alias RunicAI.Persistence.SQLite.Repo
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.Schemas.CodingEvent
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.TerminalEvent

  @schema_version 1
  @default_busy_attempts 5
  @default_busy_backoff_ms 25

  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Ecto.Adapters.SQLite3) and Code.ensure_loaded?(Ecto.Migrator)
  end

  @spec open(Path.t() | keyword()) :: {:ok, Store.t()} | {:error, Error.t()}
  def open(opts \\ [])

  def open(path) when is_binary(path), do: open(database: path)

  def open(opts) when is_list(opts) do
    if available?() do
      database = Keyword.get(opts, :database, ":memory:")
      ensure_database_dir!(database)

      repo = Keyword.get(opts, :repo, Repo)
      name = Keyword.get(opts, :name, unique_repo_name())
      opts = Keyword.put(opts, :name, name)
      repo_config = repo_config(opts, database)

      with {:ok, pid} <- repo.start_link(repo_config) do
        store =
          Store.new(
            repo: repo,
            dynamic_repo: Keyword.get(opts, :dynamic_repo, name),
            database: database,
            owner: pid,
            migrations_path: Keyword.get(opts, :migrations_path),
            metadata: Keyword.get(opts, :metadata, %{})
          )

        if Keyword.get(opts, :migrate?, true), do: migrate!(store), else: store
        {:ok, store}
      else
        {:error, reason} -> sqlite_error(reason)
      end
    else
      unavailable()
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    database = Keyword.fetch!(opts, :database)
    ensure_database_dir!(database)
    repo = Keyword.get(opts, :repo, Repo)
    name = Keyword.get(opts, :name, unique_repo_name())
    repo.start_link(repo_config(Keyword.put(opts, :name, name), database))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id:
        Keyword.get(
          opts,
          :id,
          {__MODULE__, Keyword.get(opts, :name, Keyword.get(opts, :database))}
        ),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec close(Store.t()) :: :ok | {:error, Error.t()}
  def close(%Store{owner: nil}), do: :ok

  def close(%Store{owner: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid)
    else
      :ok
    end
  catch
    :exit, reason -> sqlite_error(reason)
  end

  @impl RunicAI.Persistence.Store
  @spec migrate!(Store.t()) :: Store.t()
  def migrate!(%Store{} = store) do
    with_repo(store, fn ->
      migrations_path = migrations_path(store)

      :global.trans({{__MODULE__, :migrate, migrations_path}, self()}, fn ->
        Ecto.Migrator.run(store.repo, loaded_migrations(migrations_path), :up,
          all: true,
          log: false
        )
      end)

      record_schema_version!(store)
    end)

    store
  end

  @spec with_repo(Store.t(), (-> result)) :: result when result: term()
  def with_repo(%Store{dynamic_repo: nil}, fun) when is_function(fun, 0), do: fun.()

  def with_repo(%Store{repo: repo, dynamic_repo: dynamic_repo}, fun) when is_function(fun, 0) do
    previous = repo.get_dynamic_repo()

    try do
      repo.put_dynamic_repo(dynamic_repo)
      fun.()
    after
      repo.put_dynamic_repo(previous)
    end
  end

  @spec retry_busy_write((-> result), keyword()) :: result when result: term()
  def retry_busy_write(fun, opts \\ []) when is_function(fun, 0) do
    attempts = Keyword.get(opts, :attempts, @default_busy_attempts)
    backoff_ms = Keyword.get(opts, :backoff_ms, @default_busy_backoff_ms)
    do_retry_busy_write(fun, attempts, backoff_ms, 1)
  end

  @spec busy_error?(term()) :: boolean()
  def busy_error?(%{message: message}) when is_binary(message), do: busy_message?(message)
  def busy_error?({:error, reason}), do: busy_error?(reason)
  def busy_error?({:sqlite_error, reason}), do: busy_error?(reason)
  def busy_error?({:EXIT, reason}), do: busy_error?(reason)
  def busy_error?(reason) when is_binary(reason), do: busy_message?(reason)
  def busy_error?(reason), do: reason |> inspect() |> busy_message?()

  @impl RunicAI.Persistence.Store
  def put_artifact(%Store{} = store, artifact) when is_map(artifact) do
    content = artifact_content(artifact)
    sha256 = Map.get(artifact, :sha256, Map.get(artifact, "sha256", Patch.sha256(content)))
    ref = Map.get(artifact, :artifact_ref, Map.get(artifact, "artifact_ref", "sqlite:#{sha256}"))

    attrs =
      artifact
      |> Map.put_new(:id, ref)
      |> Map.put_new(:sha256, sha256)
      |> Map.put_new(:byte_size, byte_size(content))
      |> Map.put_new(:artifact_blob, Term.to_blob(Map.put_new(artifact, :artifact_ref, ref)))
      |> Map.put_new(
        :metadata_json,
        Map.get(artifact, :metadata, Map.get(artifact, "metadata", %{}))
      )

    result =
      with_repo(store, fn ->
        retry_busy_write(fn ->
          %RunArtifact{}
          |> RunArtifact.changeset(attrs)
          |> store.repo.insert(
            on_conflict:
              {:replace, [:sha256, :byte_size, :artifact_blob, :metadata_json, :updated_at]},
            conflict_target: :id
          )
        end)
      end)

    case result do
      {:ok, _artifact} -> {:ok, ref}
      {:error, reason} -> Persistence.normalize_result({:error, reason}, __MODULE__)
    end
  end

  @impl RunicAI.Persistence.Store
  def get_artifact(%Store{} = store, ref) when is_binary(ref) do
    with_repo(store, fn -> store.repo.get(RunArtifact, ref) end)
    |> case do
      %RunArtifact{artifact_blob: blob} when is_binary(blob) -> {:ok, Term.from_blob(blob)}
      nil -> {:error, :not_found}
      %RunArtifact{} = artifact -> {:ok, Map.from_struct(artifact)}
    end
  rescue
    exception -> sqlite_error(exception)
  end

  @impl RunicAI.Persistence.Store
  def record_event(%Store{} = store, event) when is_map(event) do
    attrs = %{
      kind: event_kind(event),
      status: event_status(event),
      artifact_ref: event_artifact_ref(event),
      event_blob: Term.to_blob(event),
      searchable_text: inspect(event, limit: :infinity),
      recorded_at: DateTime.utc_now()
    }

    result =
      with_repo(store, fn ->
        retry_busy_write(fn ->
          %CodingEvent{}
          |> CodingEvent.changeset(attrs)
          |> store.repo.insert()
        end)
      end)

    case result do
      {:ok, _event} -> :ok
      {:error, reason} -> Persistence.normalize_result({:error, reason}, __MODULE__)
    end
  end

  @spec record_terminal_event(Store.t(), RunicAI.Terminal.Event.t() | map()) ::
          {:ok, TerminalEvent.t()} | {:error, term()}
  def record_terminal_event(%Store{} = store, %RunicAI.Terminal.Event{} = event) do
    record_terminal_event(store, RunicAI.Terminal.Event.to_json_map(event))
  end

  def record_terminal_event(%Store{} = store, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("id", Map.get(attrs, :id) || Map.get(attrs, "id"))
      |> Map.put_new("at", Map.get(attrs, :at) || Map.get(attrs, "at") || DateTime.utc_now())
      |> put_event_identity_defaults()

    result =
      with_repo(store, fn ->
        retry_busy_write(fn ->
          attrs = put_event_sequence(store, attrs)

          %TerminalEvent{}
          |> TerminalEvent.changeset(attrs)
          |> store.repo.insert()
        end)
      end)

    with {:ok, %TerminalEvent{} = event} <- result do
      _ = HarnessProjection.project_terminal_event(store, event)
      {:ok, event}
    end
  end

  @spec events(Store.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def events(%Store{} = store) do
    rows =
      with_repo(store, fn ->
        store.repo.all(from(event in CodingEvent, order_by: [asc: event.id]))
      end)

    {:ok, Enum.map(rows, &Term.from_blob(&1.event_blob))}
  rescue
    exception -> sqlite_error(exception)
  end

  @spec schema_version(Store.t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def schema_version(%Store{} = store) do
    result =
      with_repo(store, fn ->
        store.repo.query!("SELECT MAX(version) FROM runic_ai_schema_versions", [])
      end)

    case result.rows do
      [[nil]] -> {:ok, 0}
      [[version]] -> {:ok, version}
    end
  rescue
    exception -> sqlite_error(exception)
  end

  defp repo_config(opts, database) do
    [
      name: Keyword.get(opts, :name, nil),
      database: database,
      pool_size: Keyword.get(opts, :pool_size, 1),
      journal_mode: Keyword.get(opts, :journal_mode, :wal),
      synchronous: Keyword.get(opts, :synchronous, :normal),
      busy_timeout: Keyword.get(opts, :busy_timeout, 15_000),
      cache_size: Keyword.get(opts, :cache_size, -64_000),
      temp_store: Keyword.get(opts, :temp_store, :memory),
      queue_target: Keyword.get(opts, :queue_target, 1_000),
      queue_interval: Keyword.get(opts, :queue_interval, 5_000),
      log: Keyword.get(opts, :log, false)
    ]
  end

  defp migrations_path(%Store{migrations_path: path}) when is_binary(path), do: path

  defp migrations_path(_store) do
    :runic_ai
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("runic_ai/repo/migrations")
  end

  defp loaded_migrations(migrations_path) do
    migrations_path
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.sort()
    |> Enum.map(fn filename ->
      version =
        filename
        |> String.split("_", parts: 2)
        |> hd()
        |> String.to_integer()

      module = migration_module(filename)

      unless Code.ensure_loaded?(module) do
        Code.require_file(Path.join(migrations_path, filename))
      end

      {version, module}
    end)
  end

  defp migration_module(filename) do
    filename
    |> String.trim_trailing(".exs")
    |> String.split("_", parts: 2)
    |> List.last()
    |> Macro.camelize()
    |> then(&Module.concat([RunicAI.Persistence.SQLite.Migrations, &1]))
  end

  defp unique_repo_name do
    Module.concat([
      RunicAI.Persistence.SQLite.Repo,
      :"Store#{System.unique_integer([:positive, :monotonic])}"
    ])
  end

  defp record_schema_version!(%Store{} = store) do
    store.repo.query!(
      """
      INSERT OR IGNORE INTO runic_ai_schema_versions(version, migrated_at)
      VALUES (?, ?)
      """,
      [@schema_version, DateTime.utc_now()]
    )
  end

  defp do_retry_busy_write(fun, attempts, backoff_ms, attempt) do
    result = fun.()

    if busy_error?(result) and attempt < attempts do
      sleep_before_retry(backoff_ms, attempt)
      do_retry_busy_write(fun, attempts, backoff_ms, attempt + 1)
    else
      result
    end
  rescue
    exception ->
      if busy_error?(exception) and attempt < attempts do
        sleep_before_retry(backoff_ms, attempt)
        do_retry_busy_write(fun, attempts, backoff_ms, attempt + 1)
      else
        reraise exception, __STACKTRACE__
      end
  catch
    :exit, reason ->
      if busy_error?(reason) and attempt < attempts do
        sleep_before_retry(backoff_ms, attempt)
        do_retry_busy_write(fun, attempts, backoff_ms, attempt + 1)
      else
        exit(reason)
      end
  end

  defp sleep_before_retry(backoff_ms, attempt) do
    Process.sleep(backoff_ms * attempt)
  end

  defp busy_message?(message) when is_binary(message) do
    message = String.downcase(message)

    String.contains?(message, "database is locked") or
      String.contains?(message, "database is busy") or
      String.contains?(message, "sqlite_busy") or
      String.contains?(message, "busy timeout")
  end

  defp ensure_database_dir!(":memory:"), do: :ok

  defp ensure_database_dir!(database) when is_binary(database) do
    database
    |> Path.expand()
    |> Path.dirname()
    |> File.mkdir_p!()
  end

  defp artifact_content(artifact) do
    case Map.get(artifact, :content, Map.get(artifact, "content", "")) do
      content when is_binary(content) -> content
      nil -> ""
      content -> inspect(content)
    end
  end

  defp event_kind(event) do
    event
    |> Map.get(:kind, Map.get(event, "kind", :coding_event))
    |> to_string()
  end

  defp event_status(event) do
    case Map.get(event, :status, Map.get(event, "status")) do
      nil -> nil
      status -> to_string(status)
    end
  end

  defp event_artifact_ref(event) do
    event
    |> Map.get(:metadata, Map.get(event, "metadata", %{}))
    |> artifact_ref_from_metadata()
  end

  defp artifact_ref_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, :artifact_ref, Map.get(metadata, "artifact_ref"))
  end

  defp artifact_ref_from_metadata(_metadata), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp put_event_identity_defaults(%{"data_json" => data} = attrs) when is_map(data) do
    attrs
    |> Map.put_new("run_id", Map.get(data, "run_id") || Map.get(attrs, "session_id"))
  end

  defp put_event_identity_defaults(%{"data" => data} = attrs) when is_map(data) do
    attrs
    |> Map.put_new("data_json", data)
    |> Map.put_new("run_id", Map.get(data, "run_id") || Map.get(attrs, "session_id"))
  end

  defp put_event_identity_defaults(attrs) do
    Map.put_new(attrs, "run_id", Map.get(attrs, "session_id"))
  end

  defp put_event_sequence(%Store{} = _store, %{"sequence" => sequence} = attrs)
       when is_integer(sequence),
       do: attrs

  defp put_event_sequence(%Store{} = store, %{"run_id" => run_id} = attrs)
       when is_binary(run_id) do
    query =
      from(event in TerminalEvent,
        where: event.run_id == ^run_id,
        select: max(event.sequence)
      )

    sequence =
      case store.repo.one(query) do
        nil -> 1
        current -> current + 1
      end

    Map.put(attrs, "sequence", sequence)
  end

  defp put_event_sequence(_store, attrs), do: attrs

  defp sqlite_error(%Error{} = error), do: {:error, error}

  defp sqlite_error(reason) do
    {:error,
     Error.from_reason(reason,
       kind: :persistence,
       message: "SQLite persistence operation failed",
       source: __MODULE__
     )}
  end

  defp unavailable do
    {:error,
     Error.new(
       :unsupported,
       "SQLite persistence is unavailable without :ecto_sqlite3",
       source: __MODULE__
     )}
  end
end
