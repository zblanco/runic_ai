defmodule RunicAI.Persistence.WorkflowTaskDurabilityTest do
  use ExUnit.Case, async: false

  require Runic

  alias Runic.Workflow
  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.RunnerStore
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Persistence.WorkflowExecutor
  alias RunicAI.Persistence.WorkflowLibrary
  alias RunicAI.Persistence.WorkflowTask
  alias RunicAI.RLM.Components.ArtifactWriter
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Node

  test "a persisted workflow_task node receives durable store and runner context" do
    root = tmp_dir("compiled-parent")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = SQLite.open(Path.join(root, "runs.db"))
    on_exit(fn -> SQLite.close(store) end)

    child = seed_reusable(store, "compiled-child", increment_workflow())
    {:ok, invoke} = Node.new("invoke_saved", :workflow_task, arguments: child.reference)

    {:ok, parent_ir} =
      IR.new("workflow:compiled-parent", "Invoke the saved increment workflow",
        nodes: %{invoke.id => invoke},
        acceptance: [%{id: "child_completed", required: true}]
      )

    workspace = Workspace.new!(root: root)
    catalog_hash = Catalog.snapshot_hash()

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: "compiled-parent",
               ir: parent_ir,
               catalog_hash: catalog_hash
             )

    assert {:ok, compiled} = Compiler.compile(created.revision.ir_json, workspace)

    assert {:ok, _artifact} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: compiled,
               compiled_hash: compiled.compiled_hash,
               catalog_hash: catalog_hash,
               metadata: %{artifact_format: "recompile_from_ir_v1"}
             })

    activate!(store, "compiled-parent")

    assert {:ok, parent} =
             WorkflowDefinitions.launch(store, "compiled-parent", %{
               id: "run:compiled-parent",
               session_id: "session:compiled-parent",
               status: :pending,
               input: %{n: 4}
             })

    {runner, runner_pid} = start_runner(store, "CompiledParent")
    on_exit(fn -> stop_runner(runner_pid) end)

    assert {:ok, _started} = WorkflowExecutor.start_run(store, parent.id, runner: runner)
    assert {:ok, completed} = WorkflowExecutor.await_terminal(store, parent.id, timeout: 5_000)
    assert completed.status == "completed"

    assert [child_run] = child_runs(store, parent.id)
    assert child_run.status == "completed"
    assert child_run.parent_node_id == "invoke_saved"
    assert child_run.definition_revision_id == child.revision.id
    assert {:ok, 5} = WorkflowExecutor.output(store, child_run.id)
  end

  test "a waiting child resumes after Runner and SQLite restart and is reused on parent re-entry" do
    root = tmp_dir("child-restart")
    database = Path.join(root, "runs.db")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = SQLite.open(database)

    child = seed_reusable(store, "restart-child", delayed_increment_workflow())

    assert {:ok, parent} =
             WorkflowDefinitions.launch(store, "restart-child", %{
               id: "run:restart-parent",
               session_id: "session:restart-child",
               status: :running
             })

    {runner_one, runner_one_pid} = start_runner(store, "RestartOne")

    invoker =
      Task.async(fn ->
        WorkflowTask.invoke(store, parent.id, child.reference, %{n: 1},
          runner: runner_one,
          parent_node_id: "invoke_restartable_child",
          timeout: 10_000
        )
      end)

    child_run = store |> await_child(parent.id) |> await_status(store, "running")
    Process.sleep(350)

    assert {:ok, waiting} =
             WorkflowExecutor.pause_for_review(
               store,
               child_run.id,
               %{checkpoint: "child_approval", prompt: "Continue this child?"},
               runner: runner_one
             )

    assert waiting.run.status == "review"
    Task.shutdown(invoker, :brutal_kill)
    stop_runner(runner_one_pid)
    :ok = SQLite.close(store)

    {:ok, reopened} = SQLite.open(database)
    on_exit(fn -> SQLite.close(reopened) end)
    {runner_two, runner_two_pid} = start_runner(reopened, "RestartTwo")
    on_exit(fn -> stop_runner(runner_two_pid) end)

    assert {:ok, decision} =
             WorkflowExecutor.decide_review(reopened, child_run.id, :approved,
               actor: "human:restart-test"
             )

    assert decision.run.status == "paused"

    assert {:ok, %{run: resumed}} =
             WorkflowTask.resume(reopened, child_run.id, runner: runner_two)

    assert resumed.status == "running"

    assert {:ok, resumed_result} =
             WorkflowTask.await_result(reopened, child_run.id,
               runner: runner_two,
               timeout: 5_000
             )

    assert resumed_result.output == 2
    assert resumed_result.child_run.status == "completed"

    assert {:ok, reused} =
             WorkflowTask.invoke(reopened, parent.id, child.reference, %{n: 1},
               runner: runner_two,
               parent_node_id: "invoke_restartable_child"
             )

    assert reused.output == 2
    assert reused.child_run.id == child_run.id
    assert reused.selection.decision == :reused_completed
    assert length(child_runs(reopened, parent.id)) == 1
  end

  test "retrying a mapped invocation restarts only its failed child" do
    root = tmp_dir("partial-fanout")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = SQLite.open(Path.join(root, "runs.db"))
    on_exit(fn -> SQLite.close(store) end)
    {:ok, counter} = Agent.start_link(fn -> %{} end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    workflow =
      Workflow.new(name: :transient_increment)
      |> Workflow.add(
        Runic.step(
          fn %{n: n} ->
            attempt =
              Agent.get_and_update(counter, fn counts ->
                attempt = Map.get(counts, n, 0) + 1
                {attempt, Map.put(counts, n, attempt)}
              end)

            if n == 2 and attempt == 1, do: raise("transient child failure")
            n + 1
          end,
          name: :increment
        )
      )

    child = seed_reusable(store, "fanout-child", workflow)

    assert {:ok, parent} =
             WorkflowDefinitions.launch(store, "fanout-child", %{
               id: "run:fanout-parent",
               session_id: "session:fanout",
               status: :running
             })

    {runner, runner_pid} = start_runner(store, "Fanout")
    on_exit(fn -> stop_runner(runner_pid) end)

    first =
      WorkflowTask.map_workflow(store, parent.id, child.reference,
        runner: runner,
        parent_node_id: "map_increment",
        retry_failed?: true,
        on_item_failure: :quarantine
      )
      |> Workflow.react_until_satisfied([%{n: 1}, %{n: 2}, %{n: 3}],
        async: true,
        timeout: 5_000
      )

    first_results =
      first
      |> Workflow.raw_productions()
      |> Enum.sort_by(& &1.input.n)

    assert [completed_one, quarantined, completed_three] = first_results
    assert completed_one.status == :completed
    assert completed_one.output == 2
    assert completed_three.status == :completed
    assert completed_three.output == 4
    assert quarantined.status == :quarantined
    assert quarantined.input == %{n: 2}
    assert quarantined.retryable?
    assert quarantined.error.code == :child_workflow_not_completed
    assert quarantined.error.details.status == "failed"
    assert is_binary(quarantined.input_hash)

    assert %{
             status: :partial,
             total_items: 3,
             completed_count: 2,
             quarantined_count: 1,
             completed_outputs: [2, 4],
             proof: %{
               all_items_accounted_for?: true,
               all_items_completed?: false,
               retryable_quarantines: 1
             }
           } = WorkflowTask.summarize_map_items(first_results)

    first_runs = child_runs(store, parent.id)
    assert length(first_runs) == 3
    assert Enum.count(first_runs, &(&1.status == "completed")) == 2
    assert Enum.count(first_runs, &(&1.status == "failed")) == 1

    second_results =
      WorkflowTask.map_workflow(store, parent.id, child.reference,
        runner: runner,
        parent_node_id: "map_increment",
        retry_failed?: true
      )
      |> Workflow.react_until_satisfied([%{n: 1}, %{n: 2}, %{n: 3}],
        async: true,
        timeout: 5_000
      )
      |> Workflow.raw_productions()
      |> Enum.sort()

    assert second_results == [2, 3, 4]
    assert Agent.get(counter, & &1) == %{1 => 1, 2 => 2, 3 => 1}

    all_runs = child_runs(store, parent.id)
    assert length(all_runs) == 4

    n2_runs = Enum.filter(all_runs, &(Term.from_blob(&1.input_blob) == %{n: 2}))
    assert Enum.map(n2_runs, & &1.attempt) |> Enum.sort() == [1, 2]
    assert Enum.map(n2_runs, & &1.status) |> Enum.sort() == ["completed", "failed"]

    retry = Enum.find(n2_runs, &(&1.attempt == 2))
    failed = Enum.find(n2_runs, &(&1.attempt == 1))
    assert retry.supersedes_run_id == failed.id
    assert retry.definition_revision_id == failed.definition_revision_id
    assert retry.compiled_hash == failed.compiled_hash
  end

  test "a retry reconciles an artifact written before the failed attempt completed" do
    root = tmp_dir("effect-reconciliation")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, store} = SQLite.open(Path.join(root, "runs.db"))
    on_exit(fn -> SQLite.close(store) end)
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)
    test_pid = self()

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
      )

    workflow =
      Workflow.new(name: :write_then_transient_failure)
      |> Workflow.add(
        Runic.step(
          fn input ->
            {:ok, artifact} =
              ArtifactWriter.run(workspace, input, %{
                path: ".docs/reconciled.md",
                write_policy: :docs_only
              })

            send(test_pid, {:artifact_effect, artifact})
            artifact
          end,
          name: :write_artifact
        )
      )
      |> Workflow.add(
        Runic.step(
          fn artifact ->
            attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
            if attempt == 1, do: raise("crash after external artifact effect")
            artifact
          end,
          name: :fail_after_effect
        ),
        to: :write_artifact
      )

    contract = %{
      inputs: %{type: "object"},
      outputs: %{type: "object"},
      effects: [:workspace_write],
      policies: %{max_runtime_ms: 5_000},
      acceptance: [%{id: "artifact persisted once", required: true}]
    }

    child = seed_reusable(store, "effect-child", workflow, public_contract: contract)

    assert {:ok, parent} =
             WorkflowDefinitions.launch(store, "effect-child", %{
               id: "run:effect-parent",
               session_id: "session:effect-reconciliation",
               status: :running
             })

    {runner, runner_pid} = start_runner(store, "EffectReconciliation")
    on_exit(fn -> stop_runner(runner_pid) end)

    input = %{text: "# Reconciled effect\n"}

    assert {:error, {:child_workflow_not_completed, "failed"}} =
             WorkflowTask.invoke(store, parent.id, child.reference, input,
               runner: runner,
               parent_node_id: "write_report"
             )

    assert_receive {:artifact_effect, first_effect}
    assert first_effect.status == :written
    assert first_effect.reconciliation.outcome == :created

    path = Path.join(root, ".docs/reconciled.md")
    assert File.read!(path) == input.text
    :ok = File.touch(path, 946_684_800)
    reconciled_mtime = File.stat!(path).mtime

    assert {:ok, retried} =
             WorkflowTask.invoke(store, parent.id, child.reference, input,
               runner: runner,
               parent_node_id: "write_report",
               retry_failed?: true
             )

    assert_receive {:artifact_effect, second_effect}
    assert second_effect.status == :reconciled
    assert second_effect.reconciliation.outcome == :matched_existing
    assert second_effect.idempotency_key == first_effect.idempotency_key
    assert retried.output.status == :reconciled
    assert retried.selection.decision == :retry_failed_child
    assert File.stat!(path).mtime == reconciled_mtime
    assert File.read!(path) == input.text
    assert Agent.get(counter, & &1) == 2

    assert child_runs(store, parent.id)
           |> Enum.sort_by(& &1.attempt)
           |> Enum.map(&{&1.attempt, &1.status}) == [{1, "failed"}, {2, "completed"}]
  end

  defp seed_reusable(store, workflow_key, native_workflow, opts \\ []) do
    {:ok, placeholder} = Node.new("placeholder", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:#{workflow_key}", "Increment a supplied integer",
        nodes: %{placeholder.id => placeholder},
        acceptance: [%{id: "incremented", required: true}]
      )

    public_contract =
      Keyword.get(opts, :public_contract, %{
        inputs: %{
          type: "object",
          required: ["n"],
          properties: %{"n" => %{type: "integer"}}
        },
        outputs: %{type: "integer"},
        effects: [],
        policies: %{max_runtime_ms: 5_000},
        acceptance: [%{id: "incremented", required: true}]
      })

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: workflow_key,
               workflow_name: "Increment integer",
               ir: ir,
               revision_metadata: %{public_contract: public_contract},
               catalog_hash: "catalog:#{workflow_key}:v1"
             )

    assert {:ok, artifact} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{workflow: native_workflow},
               compiled_hash: "compiled:#{workflow_key}:v1",
               catalog_hash: "catalog:#{workflow_key}:v1"
             })

    activate!(store, workflow_key)
    assert {:ok, resolved} = WorkflowLibrary.resolve(store, "#{workflow_key}@1")

    Map.merge(resolved, %{artifact: artifact})
  end

  defp activate!(store, workflow_key) do
    assert {:ok, _review} = WorkflowDefinitions.request_review(store, workflow_key)
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, workflow_key)
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, workflow_key)
  end

  defp increment_workflow do
    Workflow.new(name: :increment)
    |> Workflow.add(Runic.step(fn %{n: n} -> n + 1 end, name: :increment))
  end

  defp delayed_increment_workflow do
    Workflow.new(name: :delayed_increment)
    |> Workflow.add(
      Runic.step(
        fn %{n: n} ->
          Process.sleep(300)
          %{n: n + 1}
        end,
        name: :prepare
      )
    )
    |> Workflow.add(
      Runic.step(
        fn %{n: n} ->
          Process.sleep(300)
          n
        end,
        name: :finish
      ),
      to: :prepare
    )
  end

  defp child_runs(store, parent_run_id) do
    store
    |> Queries.workflow_runs_for_session(session_id_for_parent(store, parent_run_id))
    |> Enum.filter(&(&1.parent_run_id == parent_run_id))
  end

  defp session_id_for_parent(store, parent_run_id) do
    WorkflowExecutor.get_run(store, parent_run_id).session_id
  end

  defp await_child(store, parent_run_id, attempts \\ 100)

  defp await_child(_store, _parent_run_id, 0), do: flunk("child run was not created")

  defp await_child(store, parent_run_id, attempts) do
    case child_runs(store, parent_run_id) do
      [child | _rest] ->
        child

      [] ->
        Process.sleep(10)
        await_child(store, parent_run_id, attempts - 1)
    end
  end

  defp await_status(run, store, status, attempts \\ 100)

  defp await_status(run, _store, _status, 0),
    do: flunk("workflow run #{run.id} did not reach the expected status")

  defp await_status(run, store, status, attempts) do
    case WorkflowExecutor.get_run(store, run.id) do
      %{status: ^status} = current ->
        current

      _current ->
        Process.sleep(10)
        await_status(run, store, status, attempts - 1)
    end
  end

  defp start_runner(store, suffix) do
    runner = Module.concat([__MODULE__, :"Runner#{suffix}#{System.unique_integer([:positive])}"])

    {:ok, pid} =
      Runic.Runner.start_link(name: runner, store: RunnerStore, store_opts: [store: store])

    {runner, pid}
  end

  defp stop_runner(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp tmp_dir(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-workflow-task-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end
end
