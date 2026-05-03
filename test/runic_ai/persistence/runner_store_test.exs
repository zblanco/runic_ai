defmodule RunicAI.Persistence.RunnerStoreTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.Events.FactProduced
  alias Runic.Workflow.RunnableFailed
  alias RunicAI.Persistence.Inspection
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.RunnerStore
  alias RunicAI.Persistence.SQLite

  setup do
    {:ok, store} = SQLite.open(":memory:")
    on_exit(fn -> SQLite.close(store) end)
    %{store: store}
  end

  test "append and stream preserve Runic events", %{store: store} do
    event = %FactProduced{
      hash: {:fact, 1},
      value: "hello",
      ancestry: nil,
      producer_label: :input,
      weight: 1,
      meta: %{node_name: :input}
    }

    assert {:ok, 1} = RunnerStore.append(:workflow_one, [event], store)
    assert {:ok, stream} = RunnerStore.stream(:workflow_one, store)
    assert [^event] = Enum.to_list(stream)

    assert [stored] = Queries.workflow_events(store, "workflow_one")
    assert stored.sequence == 1
    assert stored.event_type == "FactProduced"
  end

  test "snapshot load and fact storage round-trip exact terms", %{store: store} do
    log = [
      %FactProduced{
        hash: :answer,
        value: %{answer: 42},
        ancestry: nil,
        producer_label: :produced,
        weight: 1,
        meta: %{}
      }
    ]

    assert :ok = RunnerStore.save(:workflow_two, log, store)
    assert {:ok, ^log} = RunnerStore.load(:workflow_two, store)

    value = %{nested: [:a, "b", 3]}
    assert :ok = RunnerStore.save_fact({:hash, 1}, value, store)
    assert {:ok, ^value} = RunnerStore.load_fact({:hash, 1}, store)
  end

  test "snapshot plus tail events loads the same log as full event replay", %{store: store} do
    snapshot_event = %FactProduced{
      hash: :snapshot,
      value: "snapshot",
      ancestry: nil,
      producer_label: :input,
      weight: 1,
      meta: %{}
    }

    tail_event = %FactProduced{
      hash: :tail,
      value: "tail",
      ancestry: nil,
      producer_label: :produced,
      weight: 1,
      meta: %{}
    }

    assert :ok = RunnerStore.save(:snapshot_tail_workflow, [snapshot_event], store)
    assert {:ok, 2} = RunnerStore.append(:snapshot_tail_workflow, [tail_event], store)

    assert {:ok, [^snapshot_event, ^tail_event]} =
             RunnerStore.load(:snapshot_tail_workflow, store)
  end

  test "failed runnables are inspectable without decoding workflow event blobs", %{store: store} do
    failed = %RunnableFailed{
      runnable_id: :runnable_one,
      node_hash: 123,
      error: {:boom, "bad input"},
      failed_at: System.monotonic_time(:millisecond),
      attempts: 2,
      failure_action: :halt
    }

    assert {:ok, 1} = RunnerStore.append(:failed_workflow, [failed], store)
    assert [event] = Queries.failed_runnables(store, "failed_workflow")
    assert event.runnable_id == "runnable_one"
    assert event.status == "error"
    assert event.error_json["json"] == ["boom", "bad input"]

    assert %{runnable_id: "runnable_one", error: %{"json" => ["boom", "bad input"]}} =
             Inspection.failed_runnable(store, "failed_workflow")
  end

  test "busy write retry reruns known SQLite busy failures" do
    {:ok, attempts} = Elixir.Agent.start_link(fn -> 0 end)

    assert :ok =
             SQLite.retry_busy_write(fn ->
               count = Elixir.Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

               if count < 3 do
                 {:error, %{message: "database is locked"}}
               else
                 :ok
               end
             end)

    assert Elixir.Agent.get(attempts, & &1) == 3
  end

  test "list, exists, and delete use durable workflow ids", %{store: store} do
    event = %FactProduced{
      hash: :one,
      value: "one",
      ancestry: nil,
      producer_label: :input,
      weight: 1,
      meta: %{}
    }

    assert {:ok, 1} = RunnerStore.append(:listed_workflow, [event], store)
    assert RunnerStore.exists?(:listed_workflow, store)
    assert {:ok, [:listed_workflow]} = RunnerStore.list(store)

    assert :ok = RunnerStore.delete(:listed_workflow, store)
    refute RunnerStore.exists?(:listed_workflow, store)
    assert {:error, :not_found} = RunnerStore.stream(:listed_workflow, store)
  end

  test "Runic.Runner can persist and resume through the SQLite store", %{store: store} do
    runner = Module.concat([__MODULE__, :"Runner#{System.unique_integer([:positive])}"])

    {:ok, runner_pid} =
      Runic.Runner.start_link(name: runner, store: RunnerStore, store_opts: [store: store])

    on_exit(fn ->
      try do
        if Process.alive?(runner_pid), do: Supervisor.stop(runner_pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    workflow =
      Workflow.new(name: :durable_runner_test)
      |> Workflow.add(Runic.step(fn %{n: n} -> n + 1 end, name: :increment))

    assert {:ok, _pid} = Runic.Runner.start_workflow(runner, :durable_workflow, workflow)
    assert :ok = Runic.Runner.run(runner, :durable_workflow, %{n: 1})
    assert :ok = wait_for_stream(store, :durable_workflow)
    assert :ok = Runic.Runner.stop(runner, :durable_workflow, persist: true)
    assert {:ok, _pid} = Runic.Runner.resume(runner, :durable_workflow)
  end

  defp wait_for_stream(store, workflow_id, attempts \\ 20)

  defp wait_for_stream(_store, _workflow_id, 0), do: flunk("workflow events were not persisted")

  defp wait_for_stream(store, workflow_id, attempts) do
    case RunnerStore.stream(workflow_id, store) do
      {:ok, stream} ->
        if Enum.to_list(stream) == [] do
          Process.sleep(25)
          wait_for_stream(store, workflow_id, attempts - 1)
        else
          :ok
        end

      {:error, :not_found} ->
        Process.sleep(25)
        wait_for_stream(store, workflow_id, attempts - 1)
    end
  end
end
