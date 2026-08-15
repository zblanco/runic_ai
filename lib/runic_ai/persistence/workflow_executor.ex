defmodule RunicAI.Persistence.WorkflowExecutor do
  @moduledoc """
  Executes revision-pinned workflow runs through a caller-owned `Runic.Runner`.

  The durable definition remains canonical. This module verifies the run's
  immutable definition and compiled-artifact pins before starting or resuming
  the native Runic workflow stored in the compiled artifact.
  """

  import Ecto.Query

  alias Runic.Workflow
  alias Runic.Workflow.FactRef
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.RunnerStore
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Persistence.Schemas.WorkflowCompiledArtifact
  alias RunicAI.Persistence.Schemas.WorkflowDefinitionRevision
  alias RunicAI.Persistence.Schemas.AgentSession
  alias RunicAI.Persistence.Schemas.ReviewRequest
  alias RunicAI.Persistence.Schemas.WorkflowRun
  alias RunicAI.Workflows.Compiler, as: WorkflowCompiler

  @terminal_statuses ["completed", "failed", "blocked", "cancelled"]
  @resumable_statuses ["paused", "waiting", "review"]
  @recompile_artifact_format "recompile_from_ir_v1"
  @native_external_fun_format "native_external_fun_v1"
  @compiled_hash_format "stable_lowering_v2"

  @spec launch_and_run(Store.t(), String.t(), term(), keyword()) ::
          {:ok, %{run: WorkflowRun.t(), pid: pid()}} | {:error, term()}
  def launch_and_run(%Store{} = store, workflow_key, input, opts \\ [])
      when is_binary(workflow_key) and is_list(opts) do
    attrs =
      opts
      |> Keyword.get(:run, %{})
      |> Map.new()
      |> Map.put(:input, input)
      |> Map.put(:status, :pending)

    with {:ok, run} <- WorkflowDefinitions.launch(store, workflow_key, attrs) do
      start_run(store, run.id, Keyword.put(opts, :input, input))
    end
  end

  @spec start_run(Store.t(), String.t(), keyword()) ::
          {:ok, %{run: WorkflowRun.t(), pid: pid()}} | {:error, term()}
  def start_run(%Store{} = store, run_id, opts \\ [])
      when is_binary(run_id) and is_list(opts) do
    with {:ok, runner} <- fetch_runner(opts),
         {:ok, run, workflow, execution_descriptor} <- load_pinned_workflow(store, run_id, opts),
         :ok <- require_status(run, ["pending"]),
         {:ok, pid} <-
           Runic.Runner.start_workflow(
             runner,
             run.id,
             strict_failure_workflow(workflow),
             worker_opts(
               store,
               opts
               |> Keyword.put(:run_id, run.id)
               |> Keyword.put(:execution_descriptor, execution_descriptor)
             )
           ),
         {:ok, running} <- update_status(store, run, :running),
         :ok <- run_and_sync(runner, run.id, run_input(run, opts), run_opts(opts)) do
      {:ok, %{run: running, pid: pid}}
    else
      {:error, reason} = error ->
        maybe_fail_pending_run(store, run_id, reason)
        error
    end
  end

  @spec pause(Store.t(), String.t(), keyword()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def pause(%Store{} = store, run_id, opts \\ []) when is_binary(run_id) and is_list(opts) do
    with {:ok, runner} <- fetch_runner(opts),
         %WorkflowRun{} = run <- get_run(store, run_id),
         :ok <- require_status(run, ["running"]),
         :ok <- Runic.Runner.checkpoint(runner, run.id),
         :ok <- Runic.Runner.stop(runner, run.id, persist: true),
         :ok <- await_runner_stopped(runner, run.id),
         %WorkflowRun{} = current <- get_run(store, run.id) do
      if current.status in @terminal_statuses do
        {:ok, current}
      else
        update_status(store, current, :paused)
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec pause_for_review(Store.t(), String.t(), map() | keyword(), keyword()) ::
          {:ok, %{run: WorkflowRun.t(), review: ReviewRequest.t()}} | {:error, term()}
  def pause_for_review(store, run_id, review_attrs, opts \\ [])

  def pause_for_review(%Store{} = store, run_id, review_attrs, opts)
      when is_binary(run_id) and is_list(review_attrs) and is_list(opts) do
    pause_for_review(store, run_id, Map.new(review_attrs), opts)
  end

  def pause_for_review(%Store{} = store, run_id, review_attrs, opts)
      when is_binary(run_id) and is_map(review_attrs) and is_list(opts) do
    with {:ok, paused} <- pause(store, run_id, opts),
         :ok <- require_status(paused, ["paused"]) do
      persist_runtime_review(store, paused, review_attrs)
    end
  end

  @spec decide_review(Store.t(), String.t(), :approved | :denied, keyword()) ::
          {:ok, %{run: WorkflowRun.t(), review: ReviewRequest.t()}} | {:error, term()}
  def decide_review(%Store{} = store, run_id, decision, opts \\ [])
      when is_binary(run_id) and decision in [:approved, :denied] and is_list(opts) do
    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        store.repo.transaction(fn ->
          review = pending_runtime_review!(store, run_id, Keyword.get(opts, :resume_key))
          run = store.repo.get(WorkflowRun, run_id) || store.repo.rollback(:not_found)

          review =
            review
            |> ReviewRequest.changeset(%{
              status: decision,
              decision_json: %{
                decision: decision,
                actor: Keyword.get(opts, :actor),
                reason: Keyword.get(opts, :reason),
                decided_at: DateTime.utc_now()
              }
            })
            |> store.repo.update!()

          run_status = if decision == :approved, do: :paused, else: :blocked

          run =
            run
            |> WorkflowRun.changeset(%{status: run_status})
            |> store.repo.update!()

          %{run: run, review: review}
        end)
      end)
    end)
    |> transaction_result()
  end

  @spec resume(Store.t(), String.t(), keyword()) ::
          {:ok, %{run: WorkflowRun.t(), pid: pid()}} | {:error, term()}
  def resume(%Store{} = store, run_id, opts \\ []) when is_binary(run_id) and is_list(opts) do
    with {:ok, runner} <- fetch_runner(opts),
         {:ok, run, workflow, execution_descriptor} <- load_pinned_workflow(store, run_id, opts),
         :ok <- require_status(run, @resumable_statuses),
         {:ok, running} <- update_status(store, run, :running) do
      resume_running(store, runner, run, running, workflow, execution_descriptor, opts)
    end
  end

  @spec await_terminal(Store.t(), String.t(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, :not_found | :timeout}
  def await_terminal(%Store{} = store, run_id, opts \\ []) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 20)
    await_terminal_until(store, run_id, System.monotonic_time(:millisecond) + timeout, interval)
  end

  @doc false
  def complete_callback(run_id, %Workflow{} = workflow, %Store{} = store) do
    complete_callback(run_id, workflow, store, nil)
  end

  @doc false
  def complete_callback(run_id, %Workflow{} = workflow, %Store{} = store, descriptor) do
    {status, attrs} = completion_status(workflow)
    attrs = attach_execution_output(attrs, status, descriptor, workflow)

    case get_run(store, to_string(run_id)) do
      %WorkflowRun{status: "failed"} = run -> {:ok, run}
      %WorkflowRun{} = run -> update_status(store, run, status, attrs)
      nil -> {:error, :not_found}
    end
  end

  @spec get_run(Store.t(), String.t()) :: WorkflowRun.t() | nil
  def get_run(%Store{} = store, run_id) do
    SQLite.with_repo(store, fn -> store.repo.get(WorkflowRun, run_id) end)
  end

  @spec record_output(Store.t(), String.t(), term()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def record_output(%Store{} = store, run_id, output) when is_binary(run_id) do
    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        case store.repo.get(WorkflowRun, run_id) do
          %WorkflowRun{} = run ->
            run
            |> WorkflowRun.changeset(%{output_blob: Term.to_blob(output)})
            |> store.repo.update()

          nil ->
            {:error, :not_found}
        end
      end)
    end)
  end

  @spec output(Store.t(), String.t()) :: {:ok, term()} | {:error, :not_found | :output_missing}
  def output(%Store{} = store, run_id) when is_binary(run_id) do
    case get_run(store, run_id) do
      %WorkflowRun{output_blob: blob} when is_binary(blob) -> {:ok, Term.from_blob(blob)}
      %WorkflowRun{} -> {:error, :output_missing}
      nil -> {:error, :not_found}
    end
  end

  @spec fail_run(Store.t(), String.t(), term()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def fail_run(%Store{} = store, run_id, reason) when is_binary(run_id) do
    case get_run(store, run_id) do
      %WorkflowRun{} = run ->
        update_status(store, run, :failed, %{
          completed_at: nil,
          error_json: %{code: :runic_runnable_failed, reason: inspect(reason)}
        })

      nil ->
        {:error, :not_found}
    end
  end

  defp load_pinned_workflow(%Store{} = store, run_id, opts) do
    SQLite.with_repo(store, fn ->
      with %WorkflowRun{} = run <- store.repo.get(WorkflowRun, run_id),
           %WorkflowDefinitionRevision{} = revision <-
             store.repo.get(WorkflowDefinitionRevision, run.definition_revision_id),
           %WorkflowCompiledArtifact{} = artifact <-
             store.repo.get(WorkflowCompiledArtifact, run.compiled_artifact_id),
           :ok <- verify_pins(run, revision, artifact),
           {:ok, persisted} <- persisted_artifact(artifact),
           {:ok, workflow, execution_descriptor} <-
             load_native_workflow(store, run, revision, artifact, persisted, opts) do
        {:ok, run, workflow, execution_descriptor}
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  # Compiled Runic graphs can contain VM-local values such as compiled Regex
  # references and closures. Persist the compilation evidence, but rebuild the
  # native graph from the immutable pinned IR before a later execution.
  defp load_native_workflow(store, run, revision, artifact, persisted, opts)
       when persisted == :recompile_from_ir or is_map_key(persisted, :ir) do
    with :ok <- verify_recompile_compatibility(artifact),
         {:ok, workspace} <- execution_workspace(store, run),
         {:ok, compiled} <-
           WorkflowCompiler.compile(
             revision.ir_json,
             workspace,
             runtime_compile_opts(store, run, opts)
           ),
         :ok <- verify_recompiled_hash(compiled.compiled_hash, artifact.compiled_hash),
         {:ok, workflow} <- extract_workflow(compiled) do
      {:ok, workflow, WorkflowCompiler.execution_descriptor(compiled)}
    end
  end

  defp load_native_workflow(_store, _run, _revision, _artifact, persisted, _opts) do
    with {:ok, workflow} <- extract_workflow(persisted) do
      {:ok, workflow, legacy_execution_descriptor(persisted)}
    end
  end

  defp runtime_compile_opts(store, run, opts) do
    opts
    |> Keyword.take([:model, :client, :receive_timeout, :llm_opts, :llm_timeout_ms])
    |> Keyword.put(:workflow_store, store)
    |> Keyword.put(:workflow_runner, Keyword.get(opts, :runner))
    |> Keyword.put(:workflow_parent_run_id, run.id)
    |> Keyword.put(:run_id, run.id)
  end

  defp execution_workspace(store, run) do
    session = store.repo.get(AgentSession, run.session_id)

    root =
      case session do
        %AgentSession{workspace_root: root} when is_binary(root) -> root
        _session -> File.cwd!()
      end

    write_policy =
      case session do
        %AgentSession{metadata_json: metadata} -> value(metadata || %{}, :write_policy, nil)
        _session -> nil
      end

    path_policy =
      case to_string(write_policy || "") do
        "docs_only" -> PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
        "workspace_review" -> PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: ["."])
        "none" -> PathPolicy.new!(hidden_policy: :deny, allowed_write_roots: ["."])
        _other -> PathPolicy.new!()
      end

    Workspace.new(root: root, path_policy: path_policy)
  end

  defp persisted_artifact(%WorkflowCompiledArtifact{} = artifact) do
    metadata = artifact.metadata_json || %{}
    format = value(metadata, :artifact_format, nil)

    cond do
      format == @recompile_artifact_format ->
        {:ok, :recompile_from_ir}

      is_nil(format) and value(metadata, :compiled_by, nil) == "workbench:human" ->
        {:ok, :recompile_from_ir}

      is_nil(format) ->
        decode_legacy_artifact(artifact)

      format == @native_external_fun_format ->
        decode_legacy_artifact(artifact)

      true ->
        {:error,
         Error.validation("compiled artifact format is not supported by this runtime",
           source: __MODULE__,
           details: %{
             code: :unsupported_compiled_artifact_format,
             artifact_id: artifact.id,
             artifact_format: format,
             supported_formats: [@recompile_artifact_format, @native_external_fun_format]
           }
         )}
    end
  end

  defp decode_legacy_artifact(artifact) do
    try do
      {:ok, Term.from_blob(artifact.artifact_blob)}
    rescue
      ArgumentError ->
        {:error,
         Error.validation("compiled artifact cannot be safely restored",
           source: __MODULE__,
           details: %{code: :unsafe_compiled_artifact, artifact_id: artifact.id}
         )}
    end
  end

  defp verify_recompile_compatibility(artifact) do
    metadata = artifact.metadata_json || %{}
    hash_format = value(metadata, :compiled_hash_format, nil)
    current_catalog_hash = RunicAI.Workflows.Catalog.snapshot_hash()

    cond do
      hash_format not in [nil, @compiled_hash_format] ->
        {:error,
         Error.validation("compiled hash format is not supported by this runtime",
           source: __MODULE__,
           details: %{
             code: :unsupported_compiled_hash_format,
             artifact_id: artifact.id,
             compiled_hash_format: hash_format,
             supported_formats: [@compiled_hash_format]
           }
         )}

      value(metadata, :catalog_compatibility, nil) == "strict_current_v1" and
        is_binary(artifact.catalog_hash) and artifact.catalog_hash != current_catalog_hash ->
        {:error,
         Error.validation("pinned catalog snapshot is unavailable in this runtime",
           source: __MODULE__,
           details: %{
             code: :pinned_catalog_snapshot_unavailable,
             artifact_id: artifact.id,
             pinned_catalog_hash: artifact.catalog_hash,
             current_catalog_hash: current_catalog_hash,
             required_action: :create_revalidated_revision
           }
         )}

      true ->
        :ok
    end
  end

  defp verify_recompiled_hash(hash, hash), do: :ok

  defp verify_recompiled_hash(actual, expected) do
    {:error,
     Error.validation("recompiled workflow does not match its pinned compiled hash",
       source: __MODULE__,
       details: %{code: :recompiled_hash_mismatch, expected: expected, actual: actual}
     )}
  end

  defp persist_runtime_review(store, paused, attrs) do
    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        store.repo.transaction(fn ->
          checkpoint = value(attrs, :checkpoint, "human_review")
          resume_key = value(attrs, :resume_key, "workflow_run:#{paused.id}:#{checkpoint}")

          pending =
            store.repo.exists?(
              from(review in ReviewRequest,
                where:
                  review.workflow_run_id == ^paused.id and
                    review.status in ["pending", "waiting"]
              )
            )

          if pending, do: store.repo.rollback(:review_already_pending)

          review =
            %ReviewRequest{}
            |> ReviewRequest.changeset(%{
              session_id: paused.session_id,
              workflow_run_id: paused.id,
              kind: value(attrs, :kind, :workflow_run),
              checkpoint: checkpoint,
              resume_key: resume_key,
              status: :pending,
              details_json: %{
                prompt: value(attrs, :prompt, nil),
                options: value(attrs, :options, ["approve", "deny"]),
                definition_revision_id: paused.definition_revision_id,
                definition_hash: paused.definition_hash,
                compiled_hash: paused.compiled_hash
              },
              decision_json: %{}
            })
            |> store.repo.insert!()

          run =
            paused
            |> WorkflowRun.changeset(%{status: :review})
            |> store.repo.update!()

          %{run: run, review: review}
        end)
      end)
    end)
    |> transaction_result()
  end

  defp pending_runtime_review!(store, run_id, nil) do
    store.repo.one(
      from(review in ReviewRequest,
        where: review.workflow_run_id == ^run_id and review.status in ["pending", "waiting"],
        order_by: [desc: review.inserted_at],
        limit: 1
      )
    ) || store.repo.rollback(:no_pending_run_review)
  end

  defp pending_runtime_review!(store, run_id, resume_key) do
    store.repo.one(
      from(review in ReviewRequest,
        where:
          review.workflow_run_id == ^run_id and review.resume_key == ^resume_key and
            review.status in ["pending", "waiting"],
        limit: 1
      )
    ) || store.repo.rollback(:no_pending_run_review)
  end

  defp verify_pins(run, revision, artifact) do
    matches? =
      revision.id == run.definition_revision_id and
        revision.semantic_hash == run.definition_hash and
        artifact.id == run.compiled_artifact_id and
        artifact.revision_id == revision.id and
        artifact.compiled_hash == run.compiled_hash and
        (is_nil(run.catalog_hash) or
           run.catalog_hash == artifact.catalog_hash or
           run.catalog_hash == revision.catalog_hash)

    if matches? do
      :ok
    else
      {:error,
       Error.validation("workflow run no longer matches its immutable execution pins",
         source: __MODULE__,
         details: %{
           code: :workflow_execution_pin_mismatch,
           run_id: run.id,
           revision_id: run.definition_revision_id,
           compiled_artifact_id: run.compiled_artifact_id
         }
       )}
    end
  end

  defp extract_workflow(%Workflow{} = workflow), do: {:ok, workflow}
  defp extract_workflow(%{workflow: %Workflow{} = workflow}), do: {:ok, workflow}
  defp extract_workflow(%{runic: %{workflow: %Workflow{} = workflow}}), do: {:ok, workflow}

  defp extract_workflow(_artifact) do
    {:error,
     Error.validation("compiled artifact does not contain a native Runic workflow",
       source: __MODULE__,
       details: %{code: :missing_native_workflow}
     )}
  end

  defp legacy_execution_descriptor(%{dialect: dialect, runic: _runic} = compiled)
       when dialect in [:component, :coding],
       do: WorkflowCompiler.execution_descriptor(compiled)

  defp legacy_execution_descriptor(_persisted), do: nil

  defp update_status(store, run, status, extra_attrs \\ %{}) do
    now = DateTime.utc_now()

    attrs =
      extra_attrs
      |> Map.put(:status, status)
      |> maybe_put_terminal_time(status, now)

    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        run
        |> WorkflowRun.changeset(attrs)
        |> store.repo.update()
      end)
    end)
  end

  defp maybe_put_terminal_time(attrs, :completed, now), do: Map.put(attrs, :completed_at, now)
  defp maybe_put_terminal_time(attrs, :failed, now), do: Map.put(attrs, :failed_at, now)
  defp maybe_put_terminal_time(attrs, _status, _now), do: attrs

  defp completion_status(%Workflow{runnable_events: events}) do
    failures =
      Enum.filter(events, fn
        %Runic.Workflow.RunnableFailed{} -> true
        _event -> false
      end)

    case failures do
      [] ->
        {:completed, %{error_json: %{}}}

      failures ->
        {:failed,
         %{
           error_json: %{
             code: :runic_runnable_failed,
             failures: Enum.map(failures, &Term.preview/1)
           }
         }}
    end
  end

  defp attach_execution_output(attrs, :completed, descriptor, workflow)
       when is_map(descriptor) do
    output =
      descriptor
      |> WorkflowCompiler.execution_result(workflow)
      |> portable_output()

    Map.put(attrs, :output_blob, Term.to_blob(output))
  end

  defp attach_execution_output(attrs, _status, _descriptor, _workflow), do: attrs

  defp portable_output(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put("__struct__", inspect(struct.__struct__))
    |> portable_output()
  end

  defp portable_output(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), portable_output(value)} end)
  end

  defp portable_output(list) when is_list(list), do: Enum.map(list, &portable_output/1)

  defp portable_output(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> portable_output()

  defp portable_output(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp portable_output(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: value

  defp portable_output(value), do: inspect(value, limit: 100, printable_limit: 8_000)

  defp fetch_runner(opts) do
    case Keyword.fetch(opts, :runner) do
      {:ok, runner} -> {:ok, runner}
      :error -> {:error, :runner_required}
    end
  end

  defp worker_opts(store, opts) do
    run_id = Keyword.get(opts, :run_id)
    execution_descriptor = Keyword.get(opts, :execution_descriptor)

    worker_opts = Keyword.get(opts, :worker_opts, [])

    hooks =
      worker_opts
      |> Keyword.get(:hooks, [])
      |> Keyword.put(:on_failed, fn _runnable, reason, _state ->
        if is_binary(run_id), do: fail_run(store, run_id, reason)
        :ok
      end)

    worker_opts
    |> Keyword.put_new(:checkpoint_strategy, :every_cycle)
    |> Keyword.put(
      :on_complete,
      {__MODULE__, :complete_callback, [store, execution_descriptor]}
    )
    |> Keyword.put(:hooks, hooks)
  end

  defp run_opts(opts), do: Keyword.get(opts, :run_opts, [])

  defp run_input(run, opts) do
    case Keyword.fetch(opts, :input) do
      {:ok, input} -> input
      :error -> if(run.input_blob, do: Term.from_blob(run.input_blob), else: %{})
    end
  end

  defp maybe_run_resume_input(runner, run, opts) do
    case Keyword.fetch(opts, :input) do
      {:ok, input} -> run_and_sync(runner, run.id, input, run_opts(opts))
      :error -> run_and_sync(runner, run.id, run_input(run, []), run_opts(opts))
    end
  end

  # Runner input is delivered by cast. Synchronize with the worker before the
  # API returns so a following checkpoint cannot overtake input planning and
  # persist only the build log.
  defp run_and_sync(runner, run_id, input, opts) do
    with :ok <- Runic.Runner.run(runner, run_id, input, opts),
         {:ok, _workflow} <- Runic.Runner.get_workflow(runner, run_id) do
      :ok
    end
  end

  defp await_runner_stopped(runner, run_id, attempts \\ 50)

  defp await_runner_stopped(_runner, _run_id, 0), do: {:error, :runner_stop_timeout}

  defp await_runner_stopped(runner, run_id, attempts) do
    case Runic.Runner.lookup(runner, run_id) do
      nil ->
        :ok

      _pid ->
        Process.sleep(10)
        await_runner_stopped(runner, run_id, attempts - 1)
    end
  end

  defp resume_running(
         store,
         runner,
         original,
         running,
         base_workflow,
         execution_descriptor,
         opts
       ) do
    with {:ok, workflow, resolver} <- replay_pinned_workflow(store, running.id, base_workflow) do
      resume_with_workflow(
        store,
        runner,
        original,
        running,
        workflow,
        resolver,
        execution_descriptor,
        opts
      )
    else
      {:error, _reason} = error ->
        _ = update_status(store, running, original.status)
        error
    end
  end

  defp resume_with_workflow(
         store,
         runner,
         original,
         running,
         workflow,
         resolver,
         execution_descriptor,
         opts
       ) do
    resume_opts =
      store
      |> worker_opts(
        opts
        |> Keyword.put(:run_id, running.id)
        |> Keyword.put(:execution_descriptor, execution_descriptor)
      )
      |> Keyword.put(:resumed, true)
      |> Keyword.put(:resolver, resolver)

    case Runic.Runner.start_workflow(runner, running.id, workflow, resume_opts) do
      {:ok, pid} ->
        case maybe_run_unless_terminal(store, runner, running, opts) do
          :ok -> {:ok, %{run: get_run(store, running.id) || running, pid: pid}}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        _ = update_status(store, running, original.status)
        error
    end
  end

  defp strict_failure_workflow(%Workflow{} = workflow) do
    policies =
      Enum.map(workflow.scheduler_policies, fn {matcher, policy} ->
        {matcher, Map.put(policy, :on_failure, :halt)}
      end)

    Workflow.set_scheduler_policies(workflow, policies)
  end

  defp replay_pinned_workflow(store, run_id, base_workflow) do
    case RunnerStore.stream(run_id, store) do
      {:ok, stream} ->
        runtime_events =
          stream
          |> Enum.reject(fn event ->
            is_struct(event, Runic.Workflow.ComponentAdded) or
              is_struct(event, Runic.Workflow.ReactionOccurred)
          end)

        workflow = Workflow.from_events(runtime_events, base_workflow, fact_mode: :ref)
        resolver = Runic.Workflow.FactResolver.new({RunnerStore, store})

        ref_hashes =
          for {hash, %FactRef{}} <- workflow.graph.vertices,
              into: MapSet.new(),
              do: hash

        {workflow, resolver} =
          Runic.Workflow.Rehydration.resolve_hot(workflow, ref_hashes, resolver)

        {:ok, workflow, resolver}

      {:error, :not_found} ->
        {:ok, base_workflow, Runic.Workflow.FactResolver.new({RunnerStore, store})}

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_run_unless_terminal(store, runner, run, opts) do
    case get_run(store, run.id) do
      %WorkflowRun{status: status} when status in @terminal_statuses ->
        :ok

      %WorkflowRun{} ->
        maybe_run_resume_input(runner, run, opts)

      nil ->
        {:error, :not_found}
    end
  end

  defp require_status(%WorkflowRun{} = run, allowed) do
    if run.status in allowed do
      :ok
    else
      {:error,
       Error.validation("workflow run is not in a valid state for this action",
         source: __MODULE__,
         details: %{
           code: :invalid_run_status,
           run_id: run.id,
           status: run.status,
           allowed: allowed
         }
       )}
    end
  end

  defp maybe_fail_pending_run(store, run_id, reason) do
    case get_run(store, run_id) do
      %WorkflowRun{status: status} = run when status in ["pending", "running"] ->
        update_status(store, run, :failed, %{error_json: %{reason: inspect(reason)}})

      _other ->
        :ok
    end
  end

  defp await_terminal_until(store, run_id, deadline, interval) do
    case get_run(store, run_id) do
      nil ->
        {:error, :not_found}

      %WorkflowRun{status: status} = run when status in @terminal_statuses ->
        {:ok, run}

      %WorkflowRun{} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval)
          await_terminal_until(store, run_id, deadline, interval)
        end
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp value(input, key, default) do
    Map.get(input, key, Map.get(input, Atom.to_string(key), default))
  end
end
