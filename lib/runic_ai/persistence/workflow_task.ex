defmodule RunicAI.Persistence.WorkflowTask do
  @moduledoc """
  Invokes an activated saved workflow as a version-pinned child run.

  A logical invocation can span process restarts. Its stable invocation key,
  attempt lineage, exact definition pins, input, and validated output are kept
  on durable workflow-run rows. Re-entering the same parent node returns a
  completed child's recorded output instead of replaying its effects.
  """

  require Runic

  import Ecto.Query

  alias Runic.Workflow
  alias RunicAI.Error
  alias RunicAI.Ids
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Persistence.WorkflowExecutor
  alias RunicAI.Persistence.WorkflowLibrary
  alias RunicAI.Persistence.Schemas.ManagedWorkflow
  alias RunicAI.Persistence.Schemas.WorkflowDefinitionRevision
  alias RunicAI.Persistence.Schemas.WorkflowRun
  alias RunicAI.Workflows.PublicContract

  @failed_statuses ["failed", "blocked", "cancelled"]
  @waiting_statuses ["paused", "waiting", "review"]
  @item_failure_modes [:halt, :quarantine]

  @spec invoke(Store.t(), String.t(), String.t() | map(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def invoke(%Store{} = store, parent_run_id, reference, input, opts \\ [])
      when is_binary(parent_run_id) and is_list(opts) do
    with {:ok, runner} <- fetch_runner(opts),
         %WorkflowRun{} = parent <- WorkflowExecutor.get_run(store, parent_run_id),
         {:ok, resolved} <- WorkflowLibrary.resolve(store, reference),
         :ok <- PublicContract.validate_input(resolved.contract, input),
         invocation_key <- invocation_key(parent, resolved.reference, input, opts),
         {:ok, child, disposition} <-
           find_or_launch_child(store, parent, resolved, input, invocation_key, opts) do
      execute_or_reuse(store, runner, child, resolved, disposition, opts)
    else
      nil -> {:error, :parent_run_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec invoke!(Store.t(), String.t(), String.t() | map(), term(), keyword()) :: term()
  def invoke!(%Store{} = store, parent_run_id, reference, input, opts \\ []) do
    case invoke(store, parent_run_id, reference, input, opts) do
      {:ok, result} ->
        result.output

      {:error, %Error{} = error} ->
        raise RuntimeError, "workflow task failed: #{error.message} (#{inspect(error.details)})"

      {:error, reason} ->
        raise RuntimeError, "workflow task failed: #{inspect(reason)}"
    end
  end

  @spec map_workflow(Store.t(), String.t(), String.t() | map(), keyword()) :: Workflow.t()
  def map_workflow(%Store{} = store, parent_run_id, reference, opts \\ [])
      when is_binary(parent_run_id) and is_list(opts) do
    name = Keyword.get(opts, :name, :workflow_map)
    on_item_failure = Keyword.get(opts, :on_item_failure, :halt)

    unless on_item_failure in @item_failure_modes do
      raise ArgumentError,
            "unknown workflow map item failure mode #{inspect(on_item_failure)}; expected one of #{inspect(@item_failure_modes)}"
    end

    invocation_opts =
      opts
      |> Keyword.delete(:child_run_id)
      |> Keyword.delete(:on_item_failure)
      |> Keyword.put_new(:parent_node_id, to_string(name))

    map =
      Runic.map(
        fn item ->
          map_item(
            ^store,
            ^parent_run_id,
            ^reference,
            item,
            ^invocation_opts,
            ^on_item_failure
          )
        end,
        name: name
      )

    Workflow.new(name: "workflow_map:#{parent_run_id}")
    |> Workflow.add(map)
  end

  @doc "Builds an explicit completion/quarantine proof from quarantining map outputs."
  @spec summarize_map_items([map()]) :: map()
  def summarize_map_items(items) when is_list(items) do
    {completed, quarantined, invalid} =
      Enum.reduce(items, {[], [], []}, fn item, {completed, quarantined, invalid} ->
        case item_status(item) do
          :completed -> {[item | completed], quarantined, invalid}
          :quarantined -> {completed, [item | quarantined], invalid}
          :invalid -> {completed, quarantined, [item | invalid]}
        end
      end)

    completed = Enum.reverse(completed)
    quarantined = Enum.reverse(quarantined)
    invalid = Enum.reverse(invalid)

    status =
      cond do
        invalid != [] -> :invalid
        quarantined == [] -> :completed
        completed == [] -> :failed
        true -> :partial
      end

    %{
      status: status,
      total_items: length(items),
      completed_count: length(completed),
      quarantined_count: length(quarantined),
      invalid_count: length(invalid),
      completed_outputs: Enum.map(completed, &map_value(&1, :output)),
      quarantined_items: quarantined,
      invalid_items: invalid,
      proof: %{
        all_items_accounted_for?: invalid == [],
        all_items_completed?: status == :completed,
        retryable_quarantines:
          Enum.count(quarantined, &(map_value(&1, :retryable?, false) == true))
      }
    }
  end

  defp item_status(item) when is_map(item) do
    case map_value(item, :status) do
      status when status in [:completed, "completed"] -> :completed
      status when status in [:quarantined, "quarantined"] -> :quarantined
      _other -> :invalid
    end
  end

  defp item_status(_item), do: :invalid

  defp map_item(store, parent_run_id, reference, item, invocation_opts, :halt) do
    invoke!(store, parent_run_id, reference, item, invocation_opts)
  end

  defp map_item(store, parent_run_id, reference, item, invocation_opts, :quarantine) do
    case invoke(store, parent_run_id, reference, item, invocation_opts) do
      {:ok, result} ->
        %{
          status: :completed,
          input: item,
          output: result.output,
          child_run_id: result.child_run.id,
          attempt: result.selection.attempt,
          selection: result.selection.decision
        }

      {:error, reason} ->
        %{
          status: :quarantined,
          input: item,
          input_hash: input_hash(item),
          error: quarantine_error(reason),
          retryable?: quarantine_retryable?(reason)
        }
    end
  end

  defp quarantine_error(%Error{} = error) do
    %{
      code: error.details[:code] || error.kind,
      message: error.message,
      details: error.details
    }
  end

  defp quarantine_error({:child_workflow_not_completed, status}) do
    %{
      code: :child_workflow_not_completed,
      message: "child workflow did not complete",
      details: %{status: status}
    }
  end

  defp quarantine_error({:child_workflow_failed, child_run_id, status}) do
    %{
      code: :child_workflow_failed,
      message: "child workflow failed",
      details: %{child_run_id: child_run_id, status: status}
    }
  end

  defp quarantine_error(reason) do
    %{
      code: :workflow_map_item_failed,
      message: "workflow map item failed",
      details: %{reason: inspect(reason, limit: 20, printable_limit: 500)}
    }
  end

  defp quarantine_retryable?(%Error{retryable?: retryable?}), do: retryable?

  defp quarantine_retryable?({code, _status})
       when code in [:child_workflow_not_completed, :child_workflow_orphaned],
       do: true

  defp quarantine_retryable?({code, _child_run_id, _status})
       when code == :child_workflow_failed,
       do: true

  defp quarantine_retryable?(_reason), do: false

  defp input_hash(input) do
    :crypto.hash(:sha256, Term.to_blob(input))
    |> Base.url_encode64(padding: false)
  end

  defp map_value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @doc "Resumes a waiting child from its immutable pinned definition."
  @spec resume(Store.t(), String.t(), keyword()) ::
          {:ok, %{run: WorkflowRun.t(), pid: pid()}} | {:error, term()}
  def resume(%Store{} = store, child_run_id, opts \\ [])
      when is_binary(child_run_id) and is_list(opts) do
    with {:ok, runner} <- fetch_runner(opts),
         %WorkflowRun{} = child <- WorkflowExecutor.get_run(store, child_run_id),
         :ok <- require_child(child),
         {:ok, started} <-
           WorkflowExecutor.resume(store, child.id, Keyword.put(opts, :runner, runner)) do
      {:ok, started}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Starts a new attempt for one failed child without changing its pinned revision."
  @spec restart(Store.t(), String.t(), keyword()) ::
          {:ok, %{run: WorkflowRun.t(), pid: pid()}} | {:error, term()}
  def restart(%Store{} = store, child_run_id, opts \\ [])
      when is_binary(child_run_id) and is_list(opts) do
    with {:ok, runner} <- fetch_runner(opts),
         %WorkflowRun{} = child <- WorkflowExecutor.get_run(store, child_run_id),
         :ok <- require_child(child),
         :ok <- require_restartable(child),
         {:ok, resolved} <- resolve_child(store, child),
         input <- run_input(child),
         :ok <- PublicContract.validate_input(resolved.contract, input),
         {:ok, retry} <-
           WorkflowDefinitions.restart_run(store, child.id, %{
             id: Keyword.get(opts, :retry_run_id),
             trigger: :workflow_task_retry,
             metadata: %{
               restart_reason: Keyword.get(opts, :reason, "retry failed workflow child")
             }
           }),
         {:ok, started} <- start_child(store, runner, retry, input, opts) do
      {:ok, started}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Waits for a child and durably records its contract-checked output."
  @spec await_result(Store.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_result(%Store{} = store, child_run_id, opts \\ [])
      when is_binary(child_run_id) and is_list(opts) do
    with {:ok, runner} <- fetch_runner(opts),
         %WorkflowRun{} = child <- WorkflowExecutor.get_run(store, child_run_id),
         :ok <- require_child(child),
         {:ok, resolved} <- resolve_child(store, child),
         {:ok, completed} <-
           WorkflowExecutor.await_terminal(store, child.id,
             timeout: Keyword.get(opts, :timeout, 30_000)
           ),
         :ok <- require_completed(completed),
         {:ok, output} <- recorded_or_runner_output(store, runner, completed),
         :ok <- validate_output(store, completed.id, resolved.contract, output),
         {:ok, recorded} <- WorkflowExecutor.record_output(store, completed.id, output) do
      {:ok, result(recorded, resolved, output, :executed)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute_or_reuse(
         store,
         _runner,
         %WorkflowRun{status: "completed"} = child,
         resolved,
         _,
         _opts
       ) do
    with {:ok, output} <- WorkflowExecutor.output(store, child.id),
         :ok <- PublicContract.validate_output(resolved.contract, output) do
      {:ok, result(child, resolved, output, :reused_completed)}
    end
  end

  defp execute_or_reuse(
         store,
         runner,
         %WorkflowRun{status: "pending"} = child,
         _resolved,
         _,
         opts
       ) do
    with {:ok, _started} <- start_child(store, runner, child, run_input(child), opts),
         {:ok, executed} <- await_result(store, child.id, Keyword.put(opts, :runner, runner)) do
      {:ok, %{executed | selection: selection(:reuse_exact, child)}}
    end
  end

  defp execute_or_reuse(
         store,
         runner,
         %WorkflowRun{status: "running"} = child,
         _resolved,
         _,
         opts
       ) do
    case Runic.Runner.lookup(runner, child.id) do
      nil -> {:error, {:child_workflow_orphaned, child.id}}
      _pid -> await_result(store, child.id, Keyword.put(opts, :runner, runner))
    end
  end

  defp execute_or_reuse(store, runner, %WorkflowRun{status: status} = child, _resolved, _, opts)
       when status in @failed_statuses do
    if Keyword.get(opts, :retry_failed?, false) do
      with {:ok, %{run: retry}} <- restart(store, child.id, Keyword.put(opts, :runner, runner)),
           {:ok, result} <- await_result(store, retry.id, Keyword.put(opts, :runner, runner)) do
        {:ok, %{result | selection: selection(:retry_failed_child, retry)}}
      end
    else
      {:error, {:child_workflow_failed, child.id, status}}
    end
  end

  defp execute_or_reuse(
         _store,
         _runner,
         %WorkflowRun{status: status} = child,
         _resolved,
         _,
         _opts
       )
       when status in @waiting_statuses,
       do: {:error, {:child_workflow_waiting, child.id, status}}

  defp execute_or_reuse(_store, _runner, child, _resolved, _disposition, _opts),
    do: {:error, {:unsupported_child_workflow_status, child.id, child.status}}

  defp find_or_launch_child(store, parent, resolved, input, nil, opts) do
    with {:ok, child} <- launch_child(store, parent, resolved, input, nil, opts) do
      {:ok, child, :launched}
    end
  end

  defp find_or_launch_child(store, parent, resolved, input, invocation_key, opts) do
    case latest_invocation(store, parent.id, invocation_key) do
      %WorkflowRun{} = child ->
        with :ok <- verify_existing_child(child, resolved, input) do
          {:ok, child, :existing}
        end

      nil ->
        case launch_child(store, parent, resolved, input, invocation_key, opts) do
          {:ok, child} ->
            {:ok, child, :launched}

          {:error, %Ecto.Changeset{}} ->
            case latest_invocation(store, parent.id, invocation_key) do
              %WorkflowRun{} = child -> {:ok, child, :existing}
              nil -> {:error, :workflow_child_invocation_conflict}
            end

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp launch_child(store, parent, resolved, input, invocation_key, opts) do
    reference = resolved.reference
    parent_node_id = Keyword.get(opts, :parent_node_id)

    WorkflowDefinitions.launch(store, resolved.workflow.workflow_key, %{
      id: Keyword.get(opts, :child_run_id, Ids.unique("run:workflow_task")),
      session_id: parent.session_id,
      status: :pending,
      trigger: :workflow_task,
      input: input,
      parent_run_id: parent.id,
      parent_node_id: parent_node_id,
      invocation_key: invocation_key,
      attempt: 1,
      expected_revision_id: reference.revision_id,
      expected_definition_hash: reference.definition_hash,
      metadata: %{
        parent_run_id: parent.id,
        parent_definition_revision_id: parent.definition_revision_id,
        parent_node_id: parent_node_id,
        invocation_key: invocation_key,
        attempt: 1,
        workflow_task_reference: reference,
        selection_decision: :reuse_exact
      }
    })
  end

  defp start_child(store, runner, child, input, opts) do
    WorkflowExecutor.start_run(store, child.id,
      runner: runner,
      input: input,
      model: Keyword.get(opts, :model),
      client: Keyword.get(opts, :client),
      receive_timeout: Keyword.get(opts, :receive_timeout),
      llm_opts: Keyword.get(opts, :llm_opts),
      llm_timeout_ms: Keyword.get(opts, :llm_timeout_ms),
      worker_opts: Keyword.get(opts, :worker_opts, []),
      run_opts: Keyword.get(opts, :run_opts, [])
    )
  end

  defp latest_invocation(store, parent_run_id, invocation_key) do
    SQLite.with_repo(store, fn ->
      store.repo.one(
        from(run in WorkflowRun,
          where: run.parent_run_id == ^parent_run_id and run.invocation_key == ^invocation_key,
          order_by: [desc: run.attempt, desc: run.inserted_at],
          limit: 1
        )
      )
    end)
  end

  defp invocation_key(parent, reference, input, opts) do
    explicit = Keyword.get(opts, :invocation_key)
    parent_node_id = Keyword.get(opts, :parent_node_id)
    child_run_id = Keyword.get(opts, :child_run_id)

    cond do
      is_binary(explicit) and explicit != "" ->
        explicit

      is_binary(child_run_id) and child_run_id != "" ->
        "child_run_id:#{child_run_id}"

      not is_nil(parent_node_id) ->
        digest =
          :crypto.hash(
            :sha256,
            Term.to_blob(%{
              parent_run_id: parent.id,
              parent_node_id: to_string(parent_node_id),
              reference: reference,
              input: input
            })
          )
          |> Base.url_encode64(padding: false)

        "workflow_task:#{digest}"

      true ->
        nil
    end
  end

  defp verify_existing_child(child, resolved, input) do
    same_input? = child.input_blob && Term.from_blob(child.input_blob) == input

    if child.definition_revision_id == resolved.revision.id and
         child.definition_hash == resolved.revision.semantic_hash and same_input? do
      :ok
    else
      {:error,
       Error.validation("workflow child invocation key was reused with different pins or input",
         source: __MODULE__,
         details: %{
           code: :workflow_child_invocation_mismatch,
           child_run_id: child.id,
           invocation_key: child.invocation_key
         }
       )}
    end
  end

  defp resolve_child(store, child) do
    workflow = WorkflowDefinitions.get(store, child.managed_workflow_id)
    revision = WorkflowDefinitions.get_revision(store, child.definition_revision_id)

    with %ManagedWorkflow{} <- workflow,
         %WorkflowDefinitionRevision{} <- revision,
         true <- revision.managed_workflow_id == workflow.id,
         true <- revision.semantic_hash == child.definition_hash,
         {:ok, contract} <- PublicContract.from_revision(workflow, revision) do
      {:ok,
       %{
         workflow: workflow,
         revision: revision,
         contract: contract,
         reference: %{
           workflow_key: workflow.workflow_key,
           revision_id: revision.id,
           revision: revision.revision,
           definition_hash: revision.semantic_hash,
           contract_hash: contract.contract_hash
         }
       }}
    else
      nil -> {:error, :not_found}
      false -> {:error, :workflow_child_pin_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp recorded_or_runner_output(store, runner, child) do
    case WorkflowExecutor.output(store, child.id) do
      {:ok, output} ->
        {:ok, output}

      {:error, :output_missing} ->
        runner_output(runner, child.id)

      {:error, _reason} = error ->
        error
    end
  end

  defp runner_output(runner, workflow_id) do
    with {:ok, workflow} <- Runic.Runner.get_workflow(runner, workflow_id) do
      if is_list(workflow.output_ports) and workflow.output_ports != [] do
        Runic.Runner.get_results(runner, workflow_id, [])
      else
        runner_sink_output(runner, workflow_id, workflow)
      end
    end
  end

  defp runner_sink_output(runner, workflow_id, workflow) do
    graph = Workflow.connected_components(workflow)

    sink_names =
      graph
      |> Multigraph.vertices()
      |> Enum.filter(&(Multigraph.out_edges(graph, &1) == []))
      |> Enum.map(& &1.name)
      |> Enum.sort()

    case sink_names do
      [] ->
        {:error, :workflow_output_component_missing}

      [name] ->
        with {:ok, results} <- Runic.Runner.get_results(runner, workflow_id, components: [name]) do
          {:ok, Map.fetch!(results, name)}
        end

      names ->
        Runic.Runner.get_results(runner, workflow_id, components: names)
    end
  end

  defp result(child, resolved, output, decision) do
    %{
      output: output,
      child_run: child,
      parent_run_id: child.parent_run_id,
      reference: resolved.reference,
      contract: resolved.contract,
      selection: selection(decision, child)
    }
  end

  defp selection(decision, child) do
    %{
      decision: decision,
      rationale: selection_rationale(decision),
      invocation_key: child.invocation_key,
      attempt: child.attempt || 1,
      supersedes_run_id: child.supersedes_run_id
    }
  end

  defp selection_rationale(:reused_completed),
    do: "returned the contract-checked output of the completed logical invocation"

  defp selection_rationale(:retry_failed_child),
    do: "retried only the failed logical child while retaining completed siblings"

  defp selection_rationale(_decision),
    do: "exact activated workflow reference passed its public input contract"

  defp validate_output(store, run_id, contract, output) do
    case PublicContract.validate_output(contract, output) do
      :ok ->
        :ok

      {:error, error} ->
        _ = WorkflowExecutor.fail_run(store, run_id, error)
        {:error, error}
    end
  end

  defp run_input(%WorkflowRun{input_blob: blob}) when is_binary(blob), do: Term.from_blob(blob)
  defp run_input(%WorkflowRun{}), do: %{}

  defp require_child(%WorkflowRun{trigger: trigger})
       when trigger in ["workflow_task", "workflow_task_retry"],
       do: :ok

  defp require_child(run), do: {:error, {:not_workflow_child, run.id}}

  defp require_restartable(%WorkflowRun{status: status}) when status in @failed_statuses, do: :ok
  defp require_restartable(run), do: {:error, {:child_not_restartable, run.id, run.status}}

  defp require_completed(%WorkflowRun{status: "completed"}), do: :ok
  defp require_completed(run), do: {:error, {:child_workflow_not_completed, run.status}}

  defp fetch_runner(opts) do
    case Keyword.fetch(opts, :runner) do
      {:ok, runner} -> {:ok, runner}
      :error -> {:error, :runner_required}
    end
  end
end
