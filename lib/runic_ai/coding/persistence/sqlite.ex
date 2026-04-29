defmodule RunicAI.Coding.Persistence.SQLite do
  @moduledoc """
  Optional SQLite-backed coding persistence store.

  This module stays behind `RunicAI.Coding.Persistence` and uses the optional
  `:exqlite` dependency when it is available. The schema is intentionally small:
  durable artifacts and generic coding events are enough for the harness to keep
  evidence without committing the package to a final session-store design.
  """

  @behaviour RunicAI.Coding.Persistence

  alias RunicAI.Coding.Patch
  alias RunicAI.Error

  @schema_version 1

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(sqlite3())

  @spec open(Path.t()) :: {:ok, term()} | {:error, Error.t()}
  def open(path \\ ":memory:") when is_binary(path) do
    if available?() do
      with {:ok, conn} <- sqlite(:open, [path, []]),
           :ok <- migrate(conn) do
        {:ok, conn}
      else
        {:error, reason} -> sqlite_error(reason)
      end
    else
      unavailable()
    end
  end

  @spec close(term()) :: :ok | {:error, Error.t()}
  def close(conn) do
    if available?() do
      case sqlite(:close, [conn]) do
        :ok -> :ok
        {:error, reason} -> sqlite_error(reason)
      end
    else
      unavailable()
    end
  end

  @spec migrate(term()) :: :ok | {:error, Error.t()}
  def migrate(conn) do
    if available?() do
      schema = """
      PRAGMA journal_mode = WAL;

      CREATE TABLE IF NOT EXISTS coding_schema_versions (
        version INTEGER PRIMARY KEY,
        migrated_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS coding_artifacts (
        ref TEXT PRIMARY KEY,
        sha256 TEXT NOT NULL,
        byte_size INTEGER NOT NULL,
        artifact_blob BLOB NOT NULL,
        stored_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS coding_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        status TEXT,
        artifact_ref TEXT,
        event_blob BLOB NOT NULL,
        searchable_text TEXT NOT NULL,
        recorded_at TEXT NOT NULL
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS coding_events_fts
      USING fts5(kind, status, searchable_text, content='coding_events', content_rowid='id');

      CREATE TRIGGER IF NOT EXISTS coding_events_ai AFTER INSERT ON coding_events BEGIN
        INSERT INTO coding_events_fts(rowid, kind, status, searchable_text)
        VALUES (new.id, new.kind, new.status, new.searchable_text);
      END;

      INSERT OR IGNORE INTO coding_schema_versions(version, migrated_at)
      VALUES (#{@schema_version}, '#{DateTime.utc_now() |> DateTime.to_iso8601()}');
      """

      case sqlite(:execute, [conn, schema]) do
        :ok -> :ok
        {:error, reason} -> sqlite_error(reason)
      end
    else
      unavailable()
    end
  end

  @impl true
  def put_artifact(conn, artifact) when is_map(artifact) do
    content = artifact_content(artifact)
    sha256 = Map.get(artifact, :sha256, Map.get(artifact, "sha256", Patch.sha256(content)))
    ref = Map.get(artifact, :artifact_ref, Map.get(artifact, "artifact_ref", "sqlite:#{sha256}"))
    stored_at = DateTime.utc_now()

    stored =
      artifact
      |> Map.put_new(:artifact_ref, ref)
      |> Map.put_new(:sha256, sha256)
      |> Map.put_new(:byte_size, byte_size(content))
      |> Map.put_new(:stored_at, stored_at)

    sql = """
    INSERT OR REPLACE INTO coding_artifacts(ref, sha256, byte_size, artifact_blob, stored_at)
    VALUES (?, ?, ?, ?, ?)
    """

    with :ok <- migrate(conn),
         :ok <-
           statement(conn, sql, [
             ref,
             sha256,
             Map.get(stored, :byte_size),
             {:blob, :erlang.term_to_binary(stored)},
             DateTime.to_iso8601(stored_at)
           ]) do
      {:ok, ref}
    end
  end

  @impl true
  def get_artifact(conn, ref) when is_binary(ref) do
    sql = "SELECT artifact_blob FROM coding_artifacts WHERE ref = ? LIMIT 1"

    with :ok <- migrate(conn),
         {:ok, rows} <- query(conn, sql, [ref]) do
      case rows do
        [[blob]] -> {:ok, :erlang.binary_to_term(blob)}
        [] -> {:error, :not_found}
      end
    end
  end

  @impl true
  def record_event(conn, event) when is_map(event) do
    recorded_at = DateTime.utc_now()
    stored = Map.put_new(event, :recorded_at, recorded_at)

    sql = """
    INSERT INTO coding_events(kind, status, artifact_ref, event_blob, searchable_text, recorded_at)
    VALUES (?, ?, ?, ?, ?, ?)
    """

    with :ok <- migrate(conn),
         :ok <-
           statement(conn, sql, [
             event_kind(stored),
             event_status(stored),
             event_artifact_ref(stored),
             {:blob, :erlang.term_to_binary(stored)},
             inspect(stored, limit: :infinity),
             DateTime.to_iso8601(recorded_at)
           ]) do
      :ok
    end
  end

  @spec events(term()) :: {:ok, [map()]} | {:error, Error.t()}
  def events(conn) do
    sql = "SELECT event_blob FROM coding_events ORDER BY id ASC"

    with :ok <- migrate(conn),
         {:ok, rows} <- query(conn, sql, []) do
      {:ok, Enum.map(rows, fn [blob] -> :erlang.binary_to_term(blob) end)}
    end
  end

  @spec schema_version(term()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def schema_version(conn) do
    sql = "SELECT MAX(version) FROM coding_schema_versions"

    with :ok <- migrate(conn),
         {:ok, [[version]]} <- query(conn, sql, []) do
      {:ok, version || 0}
    end
  end

  defp statement(conn, sql, params) do
    with {:ok, statement} <- sqlite(:prepare, [conn, sql]) do
      result =
        with :ok <- sqlite(:bind, [statement, params]),
             :done <- sqlite(:step, [conn, statement]) do
          :ok
        else
          {:error, reason} -> sqlite_error(reason)
          other -> sqlite_error(other)
        end

      _ = sqlite(:release, [conn, statement])
      result
    else
      {:error, reason} -> sqlite_error(reason)
    end
  end

  defp query(conn, sql, params) do
    with {:ok, statement} <- sqlite(:prepare, [conn, sql]) do
      result =
        with :ok <- sqlite(:bind, [statement, params]),
             {:ok, rows} <- sqlite(:fetch_all, [conn, statement]) do
          {:ok, rows}
        else
          {:error, reason} -> sqlite_error(reason)
          other -> sqlite_error(other)
        end

      _ = sqlite(:release, [conn, statement])
      result
    else
      {:error, reason} -> sqlite_error(reason)
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

  defp artifact_content(artifact) do
    case Map.get(artifact, :content, Map.get(artifact, "content", "")) do
      content when is_binary(content) -> content
      nil -> ""
      content -> inspect(content)
    end
  end

  defp sqlite(function, args), do: apply(sqlite3(), function, args)

  defp sqlite3, do: Module.concat([Exqlite, Sqlite3])

  defp sqlite_error(%Error{} = error), do: {:error, error}

  defp sqlite_error(reason) do
    {:error,
     Error.from_reason(reason,
       kind: :persistence,
       message: "SQLite coding persistence operation failed",
       source: __MODULE__
     )}
  end

  defp unavailable do
    {:error,
     Error.new(
       :unsupported,
       "SQLite persistence is unavailable without the optional :exqlite dependency",
       source: __MODULE__
     )}
  end
end
