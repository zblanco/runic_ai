defmodule RunicAI.Persistence.WorkflowExecutorTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace
  alias RunicAI.Persistence.RunnerStore
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Persistence.WorkflowExecutor
  alias RunicAI.Persistence.Schemas.AgentSession
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Node

  test "executes the pinned native artifact and resumes an interrupted run after restart" do
    root =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-pinned-executor-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    database = Path.join(root, "runs.db")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, store} = SQLite.open(database)
    workflow = delayed_workflow()
    {:ok, discover} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:pinned-executor", "Execute after a durable restart",
        nodes: %{discover.id => discover},
        acceptance: [%{id: "incremented", required: true}]
      )

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: "pinned-executor",
               ir: ir,
               catalog_hash: "catalog:pinned:v1"
             )

    assert {:ok, artifact} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{workflow: workflow},
               compiled_hash: "compiled:pinned:v1",
               catalog_hash: "catalog:pinned:v1"
             })

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, "pinned-executor")
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, "pinned-executor")
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, "pinned-executor")

    runner_one = runner_name("One")

    assert {:ok, runner_one_pid} =
             Runic.Runner.start_link(
               name: runner_one,
               store: RunnerStore,
               store_opts: [store: store]
             )

    assert {:ok, started} =
             WorkflowExecutor.launch_and_run(store, "pinned-executor", %{n: 1},
               runner: runner_one,
               run: %{id: "run:pinned-executor:1"}
             )

    assert started.run.definition_revision_id == created.revision.id
    assert started.run.compiled_artifact_id == artifact.id
    assert started.run.status == "running"

    assert {:ok, waiting} =
             WorkflowExecutor.pause_for_review(
               store,
               started.run.id,
               %{
                 checkpoint: "publish_result",
                 prompt: "Publish the computed result?"
               },
               runner: runner_one
             )

    assert waiting.run.status == "review"
    assert waiting.run.last_checkpointed_at
    assert waiting.review.status == "pending"

    assert waiting.review.resume_key ==
             "workflow_run:run:pinned-executor:1:publish_result"

    Supervisor.stop(runner_one_pid)
    :ok = SQLite.close(store)

    {:ok, reopened} = SQLite.open(database)
    on_exit(fn -> SQLite.close(reopened) end)
    runner_two = runner_name("Two")

    assert {:ok, runner_two_pid} =
             Runic.Runner.start_link(
               name: runner_two,
               store: RunnerStore,
               store_opts: [store: reopened]
             )

    on_exit(fn ->
      try do
        if Process.alive?(runner_two_pid), do: Supervisor.stop(runner_two_pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert [pending_review] = Queries.review_requests(reopened, waiting.run.id)
    assert pending_review.status == "pending"
    assert pending_review.details_json["definition_hash"] == created.revision.semantic_hash

    assert {:ok, decision} =
             WorkflowExecutor.decide_review(reopened, waiting.run.id, :approved,
               actor: "human:operator",
               reason: "result is safe to publish"
             )

    assert decision.review.status == "approved"
    assert decision.run.status == "paused"

    assert {:ok, resumed} =
             WorkflowExecutor.resume(reopened, waiting.run.id, runner: runner_two)

    assert resumed.run.status == "running"

    assert {:ok, completed} =
             WorkflowExecutor.await_terminal(reopened, waiting.run.id, timeout: 5_000)

    assert completed.status == "completed"
    assert completed.definition_revision_id == created.revision.id
    assert completed.definition_hash == created.revision.semantic_hash
    assert completed.compiled_artifact_id == artifact.id
    assert completed.compiled_hash == artifact.compiled_hash
    assert completed.catalog_hash == artifact.catalog_hash

    assert {:ok, productions} = Runic.Runner.get_results(runner_two, completed.id)
    assert 2 in productions
  end

  test "does not resurrect a run that completes while an operator pause races it" do
    root =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-review-race-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, store} = SQLite.open(Path.join(root, "runs.db"))
    on_exit(fn -> SQLite.close(store) end)

    workflow =
      Workflow.new(name: :review_race)
      |> Workflow.add(Runic.step(fn value -> value end, name: :finish_immediately))

    {:ok, discover} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:review-race", "Do not resurrect terminal runs",
        nodes: %{discover.id => discover},
        acceptance: [%{id: "completed", required: true}]
      )

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: "review-race",
               ir: ir,
               catalog_hash: "catalog:review-race:v1"
             )

    assert {:ok, _artifact} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{workflow: workflow},
               compiled_hash: "compiled:review-race:v1",
               catalog_hash: "catalog:review-race:v1"
             })

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, "review-race")
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, "review-race")
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, "review-race")

    runner = runner_name("Race")

    assert {:ok, runner_pid} =
             Runic.Runner.start_link(name: runner, store: RunnerStore, store_opts: [store: store])

    on_exit(fn ->
      try do
        if Process.alive?(runner_pid), do: Supervisor.stop(runner_pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert {:ok, started} =
             WorkflowExecutor.launch_and_run(store, "review-race", :done,
               runner: runner,
               run: %{id: "run:review-race"}
             )

    assert {:ok, completed} =
             WorkflowExecutor.await_terminal(store, started.run.id, timeout: 5_000)

    assert completed.status == "completed"

    assert {:error, %RunicAI.Error{details: %{code: :invalid_run_status}}} =
             WorkflowExecutor.pause_for_review(
               store,
               started.run.id,
               %{checkpoint: "too_late"},
               runner: runner
             )

    assert WorkflowExecutor.get_run(store, started.run.id).status == "completed"
    assert Queries.review_requests(store, started.run.id) == []
  end

  test "recompiles a pinned docs-only workflow with the session path policy" do
    root =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-docs-only-executor-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, store} = SQLite.open(Path.join(root, "runs.db"))
    on_exit(fn -> SQLite.close(store) end)

    session_id = "session:docs-only"

    SQLite.with_repo(store, fn ->
      %AgentSession{}
      |> AgentSession.changeset(%{
        id: session_id,
        agent_kind: :assistant,
        workspace_root: root,
        objective: "Write a docs artifact",
        status: :running,
        started_at: DateTime.utc_now(),
        metadata_json: %{write_policy: :docs_only}
      })
      |> store.repo.insert!()
    end)

    {:ok, write} =
      Node.new("write", :artifact_writer,
        arguments: %{path: ".docs/executor-proof.md", write_policy: :docs_only}
      )

    {:ok, ir} =
      IR.new("workflow:docs-only-executor", "Write a docs artifact",
        nodes: %{write.id => write},
        acceptance: [%{id: "artifact_written", required: true}]
      )

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
      )

    catalog_hash = Catalog.snapshot_hash()

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: "docs-only-executor",
               ir: ir,
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

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, created.workflow.id)
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, created.workflow.id)
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, created.workflow.id)

    runner = runner_name("DocsOnly")

    assert {:ok, runner_pid} =
             Runic.Runner.start_link(name: runner, store: RunnerStore, store_opts: [store: store])

    on_exit(fn ->
      try do
        if Process.alive?(runner_pid), do: Supervisor.stop(runner_pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert {:ok, started} =
             WorkflowExecutor.launch_and_run(store, created.workflow.workflow_key, "proof body",
               runner: runner,
               run: %{id: "run:docs-only-executor", session_id: session_id}
             )

    assert {:ok, completed} =
             WorkflowExecutor.await_terminal(store, started.run.id, timeout: 5_000)

    assert completed.status == "completed"
    assert {:ok, result} = WorkflowExecutor.output(store, completed.id)
    assert result["compiled_hash"] == compiled.compiled_hash
    assert [%{"path" => ".docs/executor-proof.md"}] = result["artifacts"]
    assert File.read!(Path.join(root, ".docs/executor-proof.md")) =~ "proof body"

    denied_session_id = "session:docs-denied"

    SQLite.with_repo(store, fn ->
      %AgentSession{}
      |> AgentSession.changeset(%{
        id: denied_session_id,
        agent_kind: :assistant,
        workspace_root: root,
        objective: "Reject a hidden artifact",
        status: :running,
        started_at: DateTime.utc_now(),
        metadata_json: %{write_policy: :none}
      })
      |> store.repo.insert!()
    end)

    File.rm!(Path.join(root, ".docs/executor-proof.md"))

    assert {:ok, denied} =
             WorkflowExecutor.launch_and_run(store, created.workflow.workflow_key, "must fail",
               runner: runner,
               run: %{id: "run:docs-denied", session_id: denied_session_id}
             )

    assert {:ok, failed} =
             WorkflowExecutor.await_terminal(store, denied.run.id, timeout: 15_000)

    assert failed.status == "failed"
    assert failed.error_json["code"] == "runic_runnable_failed"
    refute File.exists?(Path.join(root, ".docs/executor-proof.md"))
  end

  test "blocks unsupported artifact formats and unavailable pinned catalog snapshots precisely" do
    root =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-artifact-compatibility-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, store} = SQLite.open(Path.join(root, "runs.db"))
    on_exit(fn -> SQLite.close(store) end)

    runner = runner_name("ArtifactCompatibility")

    assert {:ok, runner_pid} =
             Runic.Runner.start_link(name: runner, store: RunnerStore, store_opts: [store: store])

    on_exit(fn ->
      try do
        if Process.alive?(runner_pid), do: Supervisor.stop(runner_pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    unsupported =
      seed_recompile_run(store, root, "unsupported-format",
        catalog_hash: Catalog.snapshot_hash(),
        metadata: %{
          artifact_format: "recompile_from_ir_v99",
          compiled_hash_format: "stable_lowering_v2"
        }
      )

    assert {:error, unsupported_error} =
             WorkflowExecutor.start_run(store, unsupported.id, runner: runner)

    assert unsupported_error.details.code == :unsupported_compiled_artifact_format
    assert unsupported_error.details.artifact_format == "recompile_from_ir_v99"

    stale =
      seed_recompile_run(store, root, "stale-catalog",
        catalog_hash: "unavailable-catalog-snapshot",
        metadata: %{
          artifact_format: "recompile_from_ir_v1",
          compiled_hash_format: "stable_lowering_v2",
          catalog_compatibility: "strict_current_v1"
        }
      )

    assert {:error, stale_error} = WorkflowExecutor.start_run(store, stale.id, runner: runner)
    assert stale_error.details.code == :pinned_catalog_snapshot_unavailable
    assert stale_error.details.required_action == :create_revalidated_revision
  end

  defp seed_recompile_run(store, root, suffix, opts) do
    {:ok, discover} = Node.new("discover", :source_discovery, arguments: %{paths: ["mix.exs"]})

    {:ok, ir} =
      IR.new("workflow:#{suffix}", "Check artifact compatibility",
        nodes: %{discover.id => discover},
        acceptance: [%{id: "checked", required: true}]
      )

    catalog_hash = Keyword.fetch!(opts, :catalog_hash)
    workspace = Workspace.new!(root: root)
    {:ok, compiled} = Compiler.compile(ir, workspace)

    {:ok, created} =
      WorkflowDefinitions.create_draft(store,
        workflow_key: suffix,
        ir: ir,
        catalog_hash: catalog_hash
      )

    {:ok, _artifact} =
      WorkflowDefinitions.record_compilation(store, created.revision.id, %{
        artifact: compiled,
        compiled_hash: compiled.compiled_hash,
        catalog_hash: catalog_hash,
        metadata: Keyword.fetch!(opts, :metadata)
      })

    {:ok, _review} = WorkflowDefinitions.request_review(store, suffix)
    {:ok, _approval} = WorkflowDefinitions.approve(store, suffix)
    {:ok, _activation} = WorkflowDefinitions.activate(store, suffix)

    {:ok, run} =
      WorkflowDefinitions.launch(store, suffix, %{
        id: "run:#{suffix}",
        session_id: "session:#{suffix}",
        status: :pending,
        input: %{}
      })

    run
  end

  defp delayed_workflow do
    Workflow.new(name: :pinned_executor_test)
    |> Workflow.add(
      Runic.step(
        fn %{n: n} ->
          Process.sleep(400)
          n + 1
        end,
        name: :increment
      )
    )
  end

  defp runner_name(suffix) do
    Module.concat([
      __MODULE__,
      String.to_atom("Runner#{suffix}#{System.unique_integer([:positive])}")
    ])
  end
end
