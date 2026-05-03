defmodule RunicAI.Persistence.ManagedWorkflowsTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Persistence.ManagedWorkflows
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.RunnerStore
  alias RunicAI.Persistence.SQLite

  setup do
    {:ok, store} = SQLite.open(":memory:")
    on_exit(fn -> SQLite.close(store) end)
    %{store: store}
  end

  test "managed workflow definitions create multiple concrete runs", %{store: store} do
    assert {:ok, workflow} =
             ManagedWorkflows.create(store, %{
               workflow_key: "docs:daily-summary",
               workflow_name: "Daily docs summary",
               definition: %{command: "daily-summary"},
               checkpoint_strategy: :on_complete,
               restart_policy: :on_failure,
               metadata_json: %{schedule: "@daily"}
             })

    assert workflow.status == "active"

    assert {:ok, first} =
             ManagedWorkflows.create_run(store, "docs:daily-summary",
               id: "run:daily:1",
               trigger: :manual,
               input: %{date: "2026-05-03"}
             )

    assert {:ok, second} =
             ManagedWorkflows.create_run(store, "docs:daily-summary",
               id: "run:daily:2",
               trigger: :cron,
               input: %{date: "2026-05-04"}
             )

    assert first.workflow_key == "docs:daily-summary"
    assert second.managed_workflow_id == workflow.id
    assert ManagedWorkflows.get(store, "docs:daily-summary").last_run_id == "run:daily:2"
    assert Queries.latest_run_for_workflow(store, "docs:daily-summary").id == "run:daily:2"
  end

  test "managed workflow status queries expose paused, failed, and scheduled work", %{
    store: store
  } do
    {:ok, _paused} =
      ManagedWorkflows.create(store, %{
        workflow_key: "paused",
        status: :paused,
        definition_kind: :term,
        definition: %{kind: :paused}
      })

    {:ok, _failed} =
      ManagedWorkflows.create(store, %{
        workflow_key: "failed",
        status: :failed,
        definition_kind: :term,
        definition: %{kind: :failed}
      })

    {:ok, _scheduled} =
      ManagedWorkflows.create(store, %{
        workflow_key: "scheduled",
        status: :scheduled,
        definition_kind: :term,
        definition: %{kind: :scheduled}
      })

    assert ["paused"] = Enum.map(ManagedWorkflows.paused(store), & &1.workflow_key)
    assert ["failed"] = Enum.map(ManagedWorkflows.failed(store), & &1.workflow_key)
    assert ["scheduled"] = Enum.map(ManagedWorkflows.scheduled(store), & &1.workflow_key)

    assert ["failed", "paused"] =
             ManagedWorkflows.resumable(store) |> Enum.map(& &1.workflow_key) |> Enum.sort()
  end

  test "managed workflow resume delegates to a caller-owned runner", %{store: store} do
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

    {:ok, workflow} =
      ManagedWorkflows.create(store, %{
        workflow_key: "resumable",
        status: :paused,
        definition_kind: :term,
        definition: %{kind: :test}
      })

    run_id = "run:resumable:1"
    {:ok, _run} = ManagedWorkflows.create_run(store, "resumable", id: run_id)

    runic_workflow =
      Workflow.new(name: :managed_resume)
      |> Workflow.add(Runic.step(fn %{n: n} -> n + 1 end, name: :increment))

    assert {:ok, _pid} = Runic.Runner.start_workflow(runner, run_id, runic_workflow)
    assert :ok = Runic.Runner.run(runner, run_id, %{n: 1})
    assert :ok = Runic.Runner.stop(runner, run_id, persist: true)

    assert ManagedWorkflows.get(store, workflow.workflow_key).last_run_id == run_id
    assert {:ok, _pid} = ManagedWorkflows.resume(store, "resumable", runner: runner)
  end
end
