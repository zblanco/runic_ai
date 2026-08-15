defmodule RunicAI.Persistence.RunnerStore do
  @moduledoc """
  Ecto SQLite implementation of `Runic.Runner.Store`.

  This adapter keeps Runic's event stream and fact-store model as the durable
  execution source while projecting enough metadata for RunicAI debugging and
  eval queries.
  """

  @behaviour Runic.Runner.Store

  import Ecto.Query

  alias Runic.Workflow.Events.Serializer
  alias RunicAI.Persistence.JSON
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.Schemas.RunnableEvent
  alias RunicAI.Persistence.Schemas.WorkflowEvent
  alias RunicAI.Persistence.Schemas.WorkflowFact
  alias RunicAI.Persistence.Schemas.WorkflowRun
  alias RunicAI.Persistence.Schemas.WorkflowSnapshot

  @impl Runic.Runner.Store
  def init_store(opts) do
    cond do
      store = Keyword.get(opts, :store) ->
        {:ok, SQLite.migrate!(store)}

      database = Keyword.get(opts, :database) ->
        SQLite.open(Keyword.put(opts, :database, database))

      true ->
        store =
          Store.new(
            repo: Keyword.get(opts, :repo, RunicAI.Persistence.SQLite.Repo),
            dynamic_repo: Keyword.get(opts, :dynamic_repo),
            database: Keyword.get(opts, :database),
            migrations_path: Keyword.get(opts, :migrations_path),
            metadata: %{runner_name: Keyword.get(opts, :runner_name)}
          )

        {:ok, SQLite.migrate!(store)}
    end
  end

  @impl Runic.Runner.Store
  def save(workflow_id, log, %Store{} = store) when is_list(log) do
    run_id = run_id(workflow_id)
    ensure_workflow_run!(store, workflow_id)

    with :ok <-
           SQLite.retry_busy_write(fn ->
             save_snapshot(workflow_id, length(log), Serializer.to_binary(log), store)
           end) do
      SQLite.with_repo(store, fn -> touch_run_sequence!(store, run_id, length(log)) end)
      :ok
    end
  rescue
    exception -> {:error, exception}
  end

  @impl Runic.Runner.Store
  def load(workflow_id, %Store{} = store) do
    case load_snapshot(workflow_id, store) do
      {:ok, {cursor, blob}} -> load_snapshot_plus_tail(workflow_id, cursor, blob, store)
      {:error, :not_found} -> stream_as_log(workflow_id, store)
      {:error, _reason} = error -> error
    end
  end

  @impl Runic.Runner.Store
  def checkpoint(workflow_id, log, %Store{} = store), do: save(workflow_id, log, store)

  @impl Runic.Runner.Store
  def append(workflow_id, events, %Store{} = store) when is_list(events) do
    run_id = run_id(workflow_id)
    ensure_workflow_run!(store, workflow_id)

    cursor =
      SQLite.with_repo(store, fn ->
        SQLite.retry_busy_write(fn ->
          store.repo.transaction(fn ->
            start_sequence = next_sequence(store, run_id)
            now = DateTime.utc_now()

            events
            |> Enum.with_index(start_sequence)
            |> Enum.each(fn {event, sequence} ->
              attrs = workflow_event_attrs(run_id, sequence, event, now)

              %WorkflowEvent{}
              |> WorkflowEvent.changeset(attrs)
              |> store.repo.insert!()

              maybe_insert_runnable_event!(store, run_id, sequence, event, now)
            end)

            cursor = start_sequence + length(events) - 1
            touch_run_sequence!(store, run_id, cursor)
            cursor
          end)
        end)
      end)

    case cursor do
      {:ok, sequence} -> {:ok, sequence}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  @spec stream_after(term(), non_neg_integer(), Store.t()) ::
          {:ok, Enumerable.t()} | {:error, :not_found | term()}
  def stream_after(workflow_id, cursor, %Store{} = store) when is_integer(cursor) do
    run_id = run_id(workflow_id)

    rows =
      SQLite.with_repo(store, fn ->
        store.repo.all(
          from(event in WorkflowEvent,
            where: event.run_id == ^run_id and event.sequence > ^cursor,
            order_by: [asc: event.sequence]
          )
        )
      end)

    stream =
      Stream.map(rows, fn %WorkflowEvent{payload_blob: blob} ->
        {:ok, event} = Serializer.event_from_binary(blob)
        event
      end)

    {:ok, stream}
  rescue
    exception -> {:error, exception}
  end

  @impl Runic.Runner.Store
  def stream(workflow_id, %Store{} = store) do
    run_id = run_id(workflow_id)

    rows =
      SQLite.with_repo(store, fn ->
        store.repo.all(
          from(event in WorkflowEvent,
            where: event.run_id == ^run_id,
            order_by: [asc: event.sequence]
          )
        )
      end)

    case rows do
      [] ->
        {:error, :not_found}

      rows ->
        stream =
          rows
          |> Stream.map(fn %WorkflowEvent{payload_blob: blob} ->
            {:ok, event} = Serializer.event_from_binary(blob)
            event
          end)

        {:ok, stream}
    end
  rescue
    exception -> {:error, exception}
  end

  @impl Runic.Runner.Store
  def save_snapshot(workflow_id, cursor, snapshot, %Store{} = store)
      when is_integer(cursor) and is_binary(snapshot) do
    run_id = run_id(workflow_id)
    ensure_workflow_run!(store, workflow_id)

    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        %WorkflowSnapshot{}
        |> WorkflowSnapshot.changeset(%{
          run_id: run_id,
          event_sequence: cursor,
          workflow_blob: snapshot,
          metadata_json: %{kind: :runner_snapshot},
          inserted_at: DateTime.utc_now()
        })
        |> store.repo.insert(
          on_conflict: {:replace, [:workflow_blob, :metadata_json, :inserted_at]},
          conflict_target: [:run_id, :event_sequence]
        )
      end)
    end)
    |> case do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  @impl Runic.Runner.Store
  def load_snapshot(workflow_id, %Store{} = store) do
    run_id = run_id(workflow_id)

    snapshot =
      SQLite.with_repo(store, fn ->
        store.repo.one(
          from(snapshot in WorkflowSnapshot,
            where: snapshot.run_id == ^run_id,
            order_by: [desc: snapshot.event_sequence],
            limit: 1
          )
        )
      end)

    case snapshot do
      nil -> {:error, :not_found}
      %WorkflowSnapshot{} = snapshot -> {:ok, {snapshot.event_sequence, snapshot.workflow_blob}}
    end
  rescue
    exception -> {:error, exception}
  end

  @impl Runic.Runner.Store
  def save_fact(fact_hash, value, %Store{} = store) do
    hash_key = Term.key(fact_hash)

    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        %WorkflowFact{}
        |> WorkflowFact.changeset(%{
          hash_key: hash_key,
          run_id: fact_run_id(fact_hash),
          producer_node: fact_producer_node(fact_hash),
          component_id: fact_component_id(fact_hash),
          value_blob: Term.to_blob(value),
          preview_json: Term.preview(value),
          inserted_at: DateTime.utc_now()
        })
        |> store.repo.insert(
          on_conflict:
            {:replace,
             [:run_id, :producer_node, :component_id, :value_blob, :preview_json, :inserted_at]},
          conflict_target: :hash_key
        )
      end)
    end)
    |> case do
      {:ok, _fact} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  @impl Runic.Runner.Store
  def load_fact(fact_hash, %Store{} = store) do
    hash_key = Term.key(fact_hash)

    fact =
      SQLite.with_repo(store, fn ->
        store.repo.get(WorkflowFact, hash_key)
      end)

    case fact do
      nil -> {:error, :not_found}
      %WorkflowFact{value_blob: blob} -> {:ok, Term.from_blob(blob)}
    end
  rescue
    exception -> {:error, exception}
  end

  @impl Runic.Runner.Store
  def delete(workflow_id, %Store{} = store) do
    run_id = run_id(workflow_id)

    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        store.repo.transaction(fn ->
          delete_all(store, WorkflowEvent, run_id)
          delete_all(store, WorkflowSnapshot, run_id)
          delete_all(store, RunnableEvent, run_id)
          store.repo.delete_all(from(run in WorkflowRun, where: run.id == ^run_id))
        end)
      end)
    end)

    :ok
  rescue
    exception -> {:error, exception}
  end

  @impl Runic.Runner.Store
  def list(%Store{} = store) do
    runs =
      SQLite.with_repo(store, fn ->
        store.repo.all(from(run in WorkflowRun, order_by: [asc: run.inserted_at]))
      end)

    {:ok, Enum.map(runs, &workflow_id_from_run/1)}
  rescue
    exception -> {:error, exception}
  end

  @impl Runic.Runner.Store
  def exists?(workflow_id, %Store{} = store) do
    run_id = run_id(workflow_id)

    SQLite.with_repo(store, fn ->
      store.repo.exists?(from(run in WorkflowRun, where: run.id == ^run_id))
    end)
  rescue
    _exception -> false
  end

  defp stream_as_log(workflow_id, store) do
    case stream(workflow_id, store) do
      {:ok, stream} -> {:ok, Enum.to_list(stream)}
      {:error, _reason} = error -> error
    end
  end

  defp load_snapshot_plus_tail(workflow_id, cursor, blob, store) do
    with {:ok, snapshot_log} <- Serializer.from_binary(blob),
         {:ok, tail_stream} <- stream_after(workflow_id, cursor, store) do
      {:ok, snapshot_log ++ Enum.to_list(tail_stream)}
    end
  end

  defp ensure_workflow_run!(%Store{} = store, workflow_id) do
    run_id = run_id(workflow_id)

    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        case store.repo.get(WorkflowRun, run_id) do
          nil ->
            %WorkflowRun{}
            |> WorkflowRun.changeset(%{
              id: run_id,
              workflow_key: run_id,
              workflow_name: workflow_name(workflow_id),
              workflow_id_blob: Term.to_blob(workflow_id),
              status: :running,
              metadata_json: %{},
              error_json: %{},
              started_at: DateTime.utc_now()
            })
            |> store.repo.insert!()

          %WorkflowRun{} ->
            :ok
        end
      end)
    end)
  end

  defp next_sequence(%Store{} = store, run_id) do
    events_query =
      from(event in WorkflowEvent,
        where: event.run_id == ^run_id,
        select: max(event.sequence)
      )

    run_query =
      from(run in WorkflowRun,
        where: run.id == ^run_id,
        select: run.last_event_sequence
      )

    [store.repo.one(events_query), store.repo.one(run_query), 0]
    |> Enum.reject(&is_nil/1)
    |> Enum.max()
    |> Kernel.+(1)
  end

  defp touch_run_sequence!(%Store{} = store, run_id, cursor) when is_integer(cursor) do
    from(run in WorkflowRun, where: run.id == ^run_id)
    |> store.repo.update_all(
      set: [
        last_event_sequence: cursor,
        last_checkpointed_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      ]
    )
  end

  defp workflow_event_attrs(run_id, sequence, event, now) do
    base = Map.from_struct(event)

    %{
      run_id: run_id,
      sequence: sequence,
      event_type: event_type(event),
      node_name: optional_string(base[:node_name] || base[:name] || runnable_node_name(event)),
      node_hash: optional_string(base[:node_hash]),
      runnable_id: optional_string(base[:runnable_id]),
      component_id: optional_string(base[:component_id]),
      component_type: optional_string(base[:component_type]),
      payload_blob: Serializer.event_to_binary(event),
      payload_json: event_preview(event),
      inserted_at: now
    }
  end

  defp maybe_insert_runnable_event!(%Store{} = store, run_id, sequence, event, now) do
    case runnable_event_attrs(run_id, sequence, event, now) do
      nil ->
        :ok

      attrs ->
        %RunnableEvent{}
        |> RunnableEvent.changeset(attrs)
        |> store.repo.insert!(
          on_conflict:
            {:replace,
             [
               :runnable_id,
               :node_name,
               :node_hash,
               :component_id,
               :component_type,
               :stage,
               :status,
               :input_preview,
               :output_preview,
               :error_json,
               :policy_json,
               :duration_ms,
               :inserted_at
             ]},
          conflict_target: [:run_id, :sequence]
        )
    end
  end

  defp runnable_event_attrs(run_id, sequence, %Runic.Workflow.RunnableDispatched{} = event, now) do
    %{
      run_id: run_id,
      sequence: sequence,
      runnable_id: optional_string(event.runnable_id),
      node_name: optional_string(event.node_name),
      node_hash: optional_string(event.node_hash),
      stage: :dispatched,
      status: :running,
      input_preview: Term.preview(event.input_fact),
      output_preview: %{},
      error_json: %{},
      policy_json: Term.preview(event.policy),
      inserted_at: now
    }
  end

  defp runnable_event_attrs(run_id, sequence, %Runic.Workflow.RunnableCompleted{} = event, now) do
    %{
      run_id: run_id,
      sequence: sequence,
      runnable_id: optional_string(event.runnable_id),
      node_hash: optional_string(event.node_hash),
      stage: :completed,
      status: :ok,
      input_preview: %{},
      output_preview: Term.preview(event.result_fact),
      error_json: %{},
      policy_json: %{},
      duration_ms: event.duration_ms,
      inserted_at: now
    }
  end

  defp runnable_event_attrs(run_id, sequence, %Runic.Workflow.RunnableFailed{} = event, now) do
    %{
      run_id: run_id,
      sequence: sequence,
      runnable_id: optional_string(event.runnable_id),
      node_hash: optional_string(event.node_hash),
      stage: :failed,
      status: :error,
      input_preview: %{},
      output_preview: %{},
      error_json: Term.preview(event.error),
      policy_json: %{
        failure_action: optional_string(event.failure_action),
        attempts: event.attempts
      },
      inserted_at: now
    }
  end

  defp runnable_event_attrs(_run_id, _sequence, _event, _now), do: nil

  defp event_type(%module{}), do: module |> Module.split() |> List.last()

  defp event_preview(event) do
    event
    |> Map.from_struct()
    |> Map.drop([:value])
    |> JSON.safe()
  end

  defp runnable_node_name(%Runic.Workflow.RunnableDispatched{node_name: node_name}),
    do: node_name

  defp runnable_node_name(_event), do: nil

  defp workflow_id_from_run(%WorkflowRun{workflow_id_blob: blob}) when is_binary(blob) do
    Term.from_blob(blob)
  end

  defp workflow_id_from_run(%WorkflowRun{id: id}), do: id

  defp run_id(workflow_id) when is_binary(workflow_id), do: workflow_id
  defp run_id(workflow_id) when is_atom(workflow_id), do: Atom.to_string(workflow_id)
  defp run_id(workflow_id), do: Term.key(workflow_id)

  defp workflow_name(workflow_id) when is_binary(workflow_id), do: workflow_id
  defp workflow_name(workflow_id) when is_atom(workflow_id), do: Atom.to_string(workflow_id)
  defp workflow_name(workflow_id), do: inspect(workflow_id)

  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(value), do: inspect(value)

  defp delete_all(%Store{} = store, schema, run_id) do
    store.repo.delete_all(from(row in schema, where: row.run_id == ^run_id))
  end

  defp fact_run_id({run_id, _producer, _component}) when is_binary(run_id), do: run_id
  defp fact_run_id(%{run_id: run_id}) when is_binary(run_id), do: run_id
  defp fact_run_id(_fact_hash), do: nil

  defp fact_producer_node({_run_id, producer, _component}), do: optional_string(producer)
  defp fact_producer_node(%{producer_node: producer}), do: optional_string(producer)
  defp fact_producer_node(_fact_hash), do: nil

  defp fact_component_id({_run_id, _producer, component}), do: optional_string(component)
  defp fact_component_id(%{component_id: component}), do: optional_string(component)
  defp fact_component_id(_fact_hash), do: nil
end
