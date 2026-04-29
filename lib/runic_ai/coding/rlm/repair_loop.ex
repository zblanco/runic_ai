defmodule RunicAI.Coding.RLM.RepairLoop do
  @moduledoc """
  Bounded verify/repair/verify loop for RLM coding runs.

  The loop treats model or child-agent repair as an implementation attempt, not
  proof. A run is only complete when deterministic verification scorecards are
  satisfied. If the loop exhausts its budget, callers can receive an explicit
  validation error instead of a misleading successful orchestration result.
  """

  alias RunicAI.Coding.Agent, as: StandardAgent
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.AcceptanceContract
  alias RunicAI.Coding.RLM.Checkpoint
  alias RunicAI.Coding.RLM.ChildResult
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.ProgressGate
  alias RunicAI.Coding.RLM.RepairAttempt
  alias RunicAI.Coding.RLM.RepairController
  alias RunicAI.Coding.RLM.RuntimeBudget
  alias RunicAI.Coding.RLM.VerificationGate
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.RLM.WorkspaceDelta
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.Episode

  @default_max_iterations 2

  @type run_result :: map()

  @spec run(run_result(), CodebaseEnvironment.t(), keyword()) ::
          {:ok, run_result()} | {:error, Error.t()}
  def run(result, %CodebaseEnvironment{} = environment, opts \\ []) when is_map(result) do
    repair_opts = Keyword.get(opts, :repair_opts, [])

    if satisfied?(result) do
      {:ok, mark_repair_status(result, :not_needed, [])}
    else
      max_iterations =
        Keyword.get(
          repair_opts,
          :max_iterations,
          Keyword.get(opts, :max_repair_iterations, @default_max_iterations)
        )

      result
      |> ensure_context()
      |> iterate(environment, opts, repair_opts, max_iterations, [])
    end
  end

  @spec satisfied?(run_result()) :: boolean()
  def satisfied?(result) when is_map(result) do
    result
    |> final_scorecard()
    |> case do
      nil -> false
      scorecard -> WorkflowScorecard.objective_satisfied?(scorecard)
    end
  end

  defp iterate(result, _environment, opts, _repair_opts, 0, history) do
    result = mark_repair_status(result, :exhausted, history)

    if fail_on_incomplete?(opts) do
      {:error,
       Error.validation("RLM repair loop exhausted before objective was satisfied",
         source: __MODULE__,
         details: %{
           repair_status: :exhausted,
           iterations: length(history),
           final_scorecard: final_scorecard(result),
           repair_history: history
         }
       )}
    else
      {:ok, result}
    end
  end

  defp iterate(result, environment, opts, repair_opts, iterations_left, history) do
    iteration = length(history) + 1
    context = Map.fetch!(result, :context)
    repair_needs = repair_needs(context)
    repair_objective = repair_objective(result, repair_needs, iteration, repair_opts)
    repair_workspace = repair_workspace(environment.workspace, result, repair_opts)

    attempt =
      run_repair_attempt(
        repair_workspace,
        repair_objective,
        opts,
        repair_opts,
        iteration,
        repair_needs
      )

    context =
      context
      |> record_repair_attempt(attempt)
      |> record_child_result(attempt.child_result, iteration)
      |> run_verification_commands(result.proposal, environment.workspace, opts, iteration)
      |> run_verification_gates(result.proposal, environment.workspace, opts, iteration)

    result =
      result
      |> refresh_result(context)
      |> ProgressGate.apply(opts)

    event = %{
      iteration: iteration,
      attempt_status: attempt.status,
      child_status: attempt.child_result.status,
      changed_files: attempt.changed_files,
      delta: Map.take(attempt.delta, [:created, :modified, :deleted]),
      error: error_summary(attempt.error),
      scorecard_status: scorecard_status(final_scorecard(result)),
      repair_needs: Enum.map(repair_needs(result.context), &repair_need_summary/1)
    }

    if satisfied?(result) do
      {:ok, mark_repair_status(result, :satisfied, history ++ [event])}
    else
      iterate(result, environment, opts, repair_opts, iterations_left - 1, history ++ [event])
    end
  end

  defp fail_on_incomplete?(opts) do
    repair_opts = Keyword.get(opts, :repair_opts, [])
    Keyword.get(repair_opts, :fail_on_incomplete?, Keyword.get(opts, :fail_on_incomplete?, true))
  end

  defp ensure_context(result) do
    Map.update!(result, :context, fn context ->
      context
      |> Map.put_new(:outputs, %{})
      |> Map.put_new(:episodes, [])
      |> Map.put_new(:trace, [])
      |> Map.put_new(:child_results, [])
      |> Map.put_new(:changed_files, [])
      |> Map.put_new(:command_results, [])
      |> Map.put_new(:verification_observations, [])
      |> Map.put_new(:scorecards, [])
      |> Map.put_new(:repair_needs, [])
      |> Map.put_new(:objective_contract, nil)
      |> Map.put_new(:objective_judgements, [])
      |> Map.put_new(:objective_evidence_summaries, [])
      |> Map.put_new(:artifacts, [])
      |> Map.put_new(:checkpoint_refs, [])
      |> Map.put_new(:repair_attempts, [])
    end)
  end

  defp final_scorecard(result) do
    result
    |> get_in([:context, :scorecards])
    |> List.wrap()
    |> List.last()
  end

  defp scorecard_status(nil), do: nil
  defp scorecard_status(%WorkflowScorecard{} = scorecard), do: scorecard.objective_status

  defp repair_needs(context) do
    scorecard = context |> Map.get(:scorecards, []) |> List.wrap() |> List.last()

    if match?(%WorkflowScorecard{}, scorecard) do
      RepairController.from_scorecard(
        scorecard,
        WorkflowScorecard.current_acceptance_results(scorecard.acceptance_results)
      )
    else
      List.wrap(Map.get(context, :repair_needs, []))
    end
  end

  defp repair_objective(result, repair_needs, iteration, repair_opts) do
    base =
      Keyword.get(repair_opts, :objective) || original_objective(result) ||
        result.proposal.objective

    """
    Repair iteration #{iteration}.

    Original objective:
    #{base}

    Blocking repair needs:
    #{inspect(Enum.map(repair_needs, &repair_need_summary/1), pretty: true, limit: 20)}

    Prior repair attempts and current handoff context:
    #{inspect(repair_handoff_summary(result), pretty: true, limit: 20)}

    Requirements:
    - Continue from the current workspace state after prior attempts; inspect
      existing files before editing and preserve any correct work already done.
    - Patch the minimal files needed to satisfy the failed checks.
    - If the failed checks show that the core deliverable is missing, implement
      the smallest complete slice of the original objective; do not stop after
      removing scaffold placeholders or making cosmetic edits.
    - Treat semantic repair instructions, failed command output, and concrete
      source/test checks as the repair acceptance checklist.
    - Replace default scaffold files with working project-specific code rather
      than deleting them and leaving references broken.
    - Run the relevant verification command before claiming completion.
    - Do not edit sibling projects or unrelated workspace files.
    - If no repair is possible within budget, report that explicitly.
    """
  end

  defp original_objective(result) do
    get_in(result, [:context, :metadata, :original_objective])
  end

  defp repair_need_summary(repair_need) do
    %{
      reason: Map.get(repair_need, :reason),
      target: Map.get(repair_need, :target),
      metadata: Map.get(repair_need, :metadata, %{})
    }
  end

  defp repair_workspace(%Workspace{} = workspace, result, repair_opts) do
    workspace_path =
      Keyword.get(repair_opts, :workspace_path) ||
        infer_workspace_path(result) ||
        "."

    if workspace_path in [nil, "", "."] do
      workspace
    else
      case Workspace.resolve_path(workspace, workspace_path, :write) do
        {:ok, resolved} ->
          Workspace.new!(
            root: resolved.path,
            persistence: workspace.persistence,
            metadata:
              Map.merge(workspace.metadata, %{
                parent_workspace_root: workspace.root,
                repair_scoped_from: resolved.relative
              })
          )

        {:error, _error} ->
          workspace
      end
    end
  end

  defp infer_workspace_path(result) do
    result.proposal.nodes
    |> Enum.reverse()
    |> Enum.find_value(fn node ->
      if node.kind == :agent do
        param(node, :workspace_path) || param(node, :cwd) || param(node, :root)
      end
    end)
    |> case do
      nil -> infer_command_cwd(result)
      value -> value
    end
  end

  defp infer_command_cwd(result) do
    result
    |> get_in([:context, :command_results])
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find_value(fn command ->
      case field(command, :cwd) do
        cwd when is_binary(cwd) ->
          case Workspace.relative_path(result.context.workspace, cwd) do
            {:ok, "."} -> nil
            {:ok, relative} -> relative
            {:error, _error} -> nil
          end

        _other ->
          nil
      end
    end)
  end

  defp run_repair_child(%Workspace{} = workspace, objective, opts, repair_opts, iteration) do
    RuntimeBudget.run(
      fn ->
        repair_opts
        |> Keyword.get(:executor)
        |> case do
          executor when is_function(executor, 3) ->
            executor.(workspace, objective, repair_child_opts(opts, repair_opts))
            |> normalize_child_result("repair:#{iteration}")

          nil ->
            workflow =
              StandardAgent.patch(workspace, objective, repair_child_opts(opts, repair_opts))

            workflow |> StandardAgent.summary() |> child_from_summary("repair:#{iteration}")
        end
      end,
      timeout_ms: Keyword.get(repair_opts, :max_child_runtime_ms),
      stage: :repair_child,
      objective: objective
    )
  end

  defp run_repair_attempt(
         %Workspace{} = workspace,
         objective,
         opts,
         repair_opts,
         iteration,
         repair_needs
       ) do
    started_at = DateTime.utc_now()
    before_snapshot = WorkspaceDelta.snapshot(workspace, workspace_delta_opts(repair_opts))

    child_result =
      workspace
      |> run_repair_child(objective, opts, repair_opts, iteration)
      |> normalize_attempt_child(iteration)

    after_snapshot = WorkspaceDelta.snapshot(workspace, workspace_delta_opts(repair_opts))
    delta = WorkspaceDelta.diff(before_snapshot, after_snapshot)
    delta_changed_files = WorkspaceDelta.changed_paths(delta)
    child_result = merge_changed_files(child_result, delta_changed_files)
    completed_at = DateTime.utc_now()
    status = attempt_status(child_result.status, child_result.metadata)

    metadata = %{
      repair_need_count: length(repair_needs),
      child_metadata: child_result.metadata,
      checkpoint_ref: nil
    }

    attempt =
      RepairAttempt.new!(
        iteration: iteration,
        status: status,
        workspace_root: workspace.root,
        started_at: started_at,
        completed_at: completed_at,
        changed_files: child_result.changed_files,
        delta: delta,
        child_result: child_result,
        error: Map.get(child_result.metadata, :error),
        metadata: metadata
      )

    checkpoint_ref =
      Checkpoint.record_best_effort(
        workspace.persistence,
        :repair_attempt,
        repair_attempt_payload(attempt),
        run_id: Checkpoint.run_id(opts),
        status: attempt.status,
        metadata: %{iteration: iteration}
      )

    %{attempt | metadata: %{metadata | checkpoint_ref: checkpoint_ref}}
  end

  defp workspace_delta_opts(repair_opts) do
    [max_files: Keyword.get(repair_opts, :snapshot_max_files, 1_000)]
  end

  defp normalize_attempt_child({:ok, %ChildResult{} = child}, _iteration), do: child

  defp normalize_attempt_child({:error, %Error{} = error}, iteration) do
    status =
      if error.kind == :timeout and field(error.details, :stage) == :repair_child do
        :partial
      else
        :failed
      end

    ChildResult.new!(status,
      id: "repair:#{iteration}:#{error.kind}",
      changed_files: [],
      unresolved_risks: [error.message],
      summary: child_error_summary(error),
      metadata: %{
        source: :repair_loop,
        error: error,
        timeout?: error.kind == :timeout
      }
    )
  end

  defp merge_changed_files(%ChildResult{} = child, changed_files) do
    %{
      child
      | changed_files:
          child.changed_files
          |> List.wrap()
          |> Kernel.++(List.wrap(changed_files))
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Enum.sort()
    }
  end

  defp attempt_status(:completed, metadata) do
    if Map.get(metadata, :timeout?) do
      :timeout
    else
      :completed
    end
  end

  defp attempt_status(_status, %{timeout?: true}), do: :timeout
  defp attempt_status(:failed, _metadata), do: :failed
  defp attempt_status(_status, _metadata), do: :partial

  defp child_error_summary(%Error{kind: :timeout}) do
    "Repair child timed out; workspace changes were captured and verification will decide whether they are useful."
  end

  defp child_error_summary(%Error{} = error), do: "Repair child failed: #{error.message}"

  defp repair_attempt_payload(%RepairAttempt{} = attempt) do
    %{
      id: attempt.id,
      iteration: attempt.iteration,
      status: attempt.status,
      workspace_root: attempt.workspace_root,
      started_at: attempt.started_at,
      completed_at: attempt.completed_at,
      changed_files: attempt.changed_files,
      delta: attempt.delta,
      child_result: attempt.child_result,
      error: error_summary(attempt.error),
      metadata: attempt.metadata
    }
  end

  defp repair_child_opts(opts, repair_opts) do
    opts
    |> Keyword.get(:agent_opts, [])
    |> Keyword.merge(Keyword.get(repair_opts, :agent_opts, []))
    |> Keyword.put_new(:model, Keyword.get(opts, :model))
    |> Keyword.put_new(:client, Keyword.get(opts, :client))
    |> Keyword.put_new(:review_gates?, Keyword.get(opts, :agent_review_gates?, true))
    |> Keyword.put_new(:max_turns, Keyword.get(repair_opts, :max_child_turns, 12))
    |> Keyword.put_new(:max_tool_calls, Keyword.get(repair_opts, :max_tool_calls, 80))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_child_result({:ok, %ChildResult{} = child}, _id), do: {:ok, child}
  defp normalize_child_result(%ChildResult{} = child, _id), do: {:ok, child}

  defp normalize_child_result({:ok, summary}, id) when is_map(summary),
    do: child_from_summary(summary, id)

  defp normalize_child_result(summary, id) when is_map(summary),
    do: child_from_summary(summary, id)

  defp normalize_child_result({:error, %Error{} = error}, _id), do: {:error, error}

  defp normalize_child_result({:error, reason}, _id) do
    {:error, Error.from_reason(reason, source: __MODULE__)}
  end

  defp normalize_child_result(other, _id) do
    {:error,
     Error.validation("repair executor returned an unsupported result",
       source: __MODULE__,
       details: %{result: inspect(other, limit: 20)}
     )}
  end

  defp child_from_summary(summary, id) do
    {:ok, ChildResult.from_agent_summary(summary, nil, id: id)}
  end

  defp record_repair_attempt(context, %RepairAttempt{} = attempt) do
    episode = repair_episode(attempt.id, :repair_attempt, attempt)

    context
    |> update_in([:repair_attempts], &append_unique(&1, attempt, fn attempt -> attempt.id end))
    |> update_in([:changed_files], &Enum.uniq(List.wrap(&1) ++ attempt.changed_files))
    |> put_in([:outputs, attempt.id], attempt)
    |> update_checkpoint_refs(attempt.metadata.checkpoint_ref)
    |> update_in([:episodes], &append_unique(&1, episode, fn episode -> episode.id end))
    |> update_in(
      [:trace],
      &append_unique(
        &1,
        %{node_id: attempt.id, kind: :repair_attempt, status: episode.status},
        fn event ->
          {event.node_id, event.kind, event.status}
        end
      )
    )
  end

  defp update_checkpoint_refs(context, nil), do: context

  defp update_checkpoint_refs(context, checkpoint_ref) when is_binary(checkpoint_ref) do
    update_in(context, [:checkpoint_refs], &Enum.uniq(List.wrap(&1) ++ [checkpoint_ref]))
  end

  defp record_child_result(context, %ChildResult{} = child_result, iteration) do
    episode = repair_episode("repair:#{iteration}:child", :agent, child_result)

    context
    |> update_in([:child_results], &append_unique(&1, child_result, fn child -> child.id end))
    |> update_in([:changed_files], &Enum.uniq(List.wrap(&1) ++ child_result.changed_files))
    |> put_in([:outputs, "repair:#{iteration}:child"], child_result)
    |> update_in([:episodes], &append_unique(&1, episode, fn episode -> episode.id end))
    |> update_in(
      [:trace],
      &append_unique(
        &1,
        %{node_id: "repair:#{iteration}:child", kind: :agent, status: episode.status},
        fn event ->
          {event.node_id, event.kind, event.status}
        end
      )
    )
  end

  defp run_verification_commands(
         context,
         %WorkflowProposal{} = proposal,
         workspace,
         opts,
         iteration
       ) do
    commands = verification_commands(proposal, opts)

    Enum.reduce(commands, context, fn command_args, context ->
      policy =
        Keyword.get_lazy(opts, :command_policy, fn ->
          CommandPolicy.new!(allowed_commands: ["mix", "git"], allow_shell: false)
        end)

      case Tools.run_command(workspace, command_args, policy) do
        {:ok, result} ->
          node_id = "repair:#{iteration}:command:#{:erlang.phash2(command_args)}"
          episode = repair_episode(node_id, :command, result)

          context
          |> update_in([:command_results], &Enum.uniq(List.wrap(&1) ++ [result]))
          |> put_in([:outputs, node_id], result)
          |> update_in([:episodes], &append_unique(&1, episode, fn episode -> episode.id end))
          |> update_in(
            [:trace],
            &append_unique(
              &1,
              %{node_id: node_id, kind: :command, status: episode.status},
              fn event ->
                {event.node_id, event.kind, event.status}
              end
            )
          )

        {:error, _error} ->
          context
      end
    end)
  end

  defp verification_commands(%WorkflowProposal{} = proposal, opts) do
    proposal.nodes
    |> Enum.filter(&(&1.kind == :verification_gate))
    |> Enum.flat_map(&verification_checks(&1, proposal.objective))
    |> Kernel.++(repair_verification_checks(opts))
    |> Enum.filter(&(&1.type in [:command_passes, :command_fails_with]))
    |> Enum.map(&command_args_from_check/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp repair_verification_checks(opts) do
    opts
    |> Keyword.get(:repair_opts, [])
    |> Keyword.get(:verification_commands, [])
    |> List.wrap()
    |> Enum.flat_map(fn input ->
      case AcceptanceCheck.from_input(input) do
        {:ok, check} -> [check]
        {:error, _error} -> []
      end
    end)
  end

  defp verification_checks(node, objective) do
    contract =
      case param(node, :contract) do
        nil ->
          %{objective: objective, checks: List.wrap(param(node, :checks))}

        value when is_map(value) ->
          value
          |> put_new_key(:objective, objective)
          |> put_new_key(:checks, List.wrap(param(node, :checks)))

        value ->
          value
      end

    case AcceptanceContract.from_input(contract) do
      {:ok, contract} -> contract.checks
      {:error, _error} -> []
    end
  end

  defp command_args_from_check(%AcceptanceCheck{} = check) do
    args = normalize_map(check_param(check, :args) || %{})

    argv =
      check_param(check, :argv) || check_param(check, :command) || field(args, :argv) ||
        field(args, :command)

    cwd = check_param(check, :cwd) || field(args, :cwd) || "."
    timeout_ms = check_param(check, :timeout_ms) || field(args, :timeout_ms)

    cond do
      is_list(argv) ->
        %{argv: argv, cwd: cwd, timeout_ms: timeout_ms}

      is_binary(argv) ->
        %{argv: split_command(argv), cwd: cwd, timeout_ms: timeout_ms}

      true ->
        nil
    end
    |> case do
      nil -> nil
      args -> Enum.reject(args, fn {_key, value} -> is_nil(value) end) |> Map.new()
    end
  end

  defp run_verification_gates(context, %WorkflowProposal{} = proposal, workspace, opts, iteration) do
    proposal.nodes
    |> Enum.filter(&(&1.kind == :verification_gate))
    |> Enum.reduce(context, fn node, context ->
      contract = verification_contract(node, proposal.objective)

      verification_context =
        context
        |> Map.take([
          :child_results,
          :changed_files,
          :command_results,
          :verification_observations,
          :verifications,
          :runtime_smokes,
          :artifacts,
          :risks
        ])
        |> Map.put(:parent_outputs, [])

      case VerificationGate.run(
             workspace,
             contract,
             verification_context,
             Keyword.get(opts, :verification_gate_opts, [])
           ) do
        {:ok, output} ->
          node_id = "repair:#{iteration}:gate:#{node.id}"
          episode = repair_episode(node_id, :verification_gate, output)

          context
          |> update_in(
            [:verification_observations],
            &Enum.uniq(List.wrap(&1) ++ acceptance_results(output))
          )
          |> update_in(
            [:scorecards],
            &append_unique(&1, output.scorecard, fn scorecard -> scorecard.id end)
          )
          |> update_in([:repair_needs], &Enum.uniq(List.wrap(&1) ++ output.repair_needs))
          |> put_in([:outputs, node_id], output)
          |> update_in([:episodes], &append_unique(&1, episode, fn episode -> episode.id end))
          |> update_in(
            [:trace],
            &append_unique(
              &1,
              %{node_id: node_id, kind: :verification_gate, status: episode.status},
              fn event ->
                {event.node_id, event.kind, event.status}
              end
            )
          )

        {:error, _error} ->
          context
      end
    end)
  end

  defp verification_contract(node, objective) do
    case param(node, :contract) do
      nil ->
        %{objective: objective, checks: List.wrap(param(node, :checks))}

      contract when is_map(contract) ->
        contract
        |> put_new_key(:objective, objective)
        |> put_new_key(:checks, List.wrap(param(node, :checks)))

      contract ->
        contract
    end
  end

  defp acceptance_results(output), do: get_in(output, [:evaluation, :results]) || []

  defp repair_episode(node_id, kind, outcome) do
    status =
      case kind do
        :agent ->
          ChildResult.episode_status(outcome)

        :repair_attempt ->
          repair_attempt_episode_status(outcome)

        :command ->
          command_episode_status(outcome)

        :verification_gate ->
          if output_status(outcome) in [:objective_satisfied, "objective_satisfied"] do
            :satisfied
          else
            :partial
          end
      end

    Episode.new!(status, outcome,
      id: "episode:#{node_id}",
      parent_node_id: node_id,
      worker_id: "rlm-repair:#{kind}",
      artifacts: List.wrap(outcome),
      metadata: %{node_kind: kind, repair?: true}
    )
  end

  defp repair_attempt_episode_status(%RepairAttempt{status: :completed}), do: :satisfied
  defp repair_attempt_episode_status(%RepairAttempt{status: :timeout}), do: :partial
  defp repair_attempt_episode_status(%RepairAttempt{status: :partial}), do: :partial
  defp repair_attempt_episode_status(%RepairAttempt{status: :failed}), do: :failed

  defp command_episode_status(%{status: :pass}), do: :satisfied
  defp command_episode_status(%{status: "pass"}), do: :satisfied
  defp command_episode_status(%{status: :blocked}), do: :blocked
  defp command_episode_status(_result), do: :failed

  defp output_status(output) when is_map(output),
    do: Map.get(output, :status, Map.get(output, "status"))

  defp output_status(_output), do: nil

  defp refresh_result(result, context) do
    result
    |> Map.put(:context, context)
    |> Map.put(:episodes, context.episodes)
    |> Map.put(:trace, context.trace)
    |> Map.put(:output, latest_output(context))
  end

  defp latest_output(context) do
    context.scorecards
    |> List.wrap()
    |> List.last()
    |> case do
      nil -> context.outputs
      scorecard -> scorecard
    end
  end

  defp mark_repair_status(result, status, history) do
    result
    |> Map.put(:repair_status, status)
    |> Map.put(:repair_iterations, history)
  end

  defp repair_handoff_summary(result) do
    context = Map.get(result, :context, %{})
    scorecard = final_scorecard(result)

    %{
      recent_attempts:
        context
        |> Map.get(:repair_attempts, [])
        |> Enum.take(-3)
        |> Enum.map(&repair_attempt_summary/1),
      blocking_acceptance:
        scorecard
        |> blocking_acceptance_summaries()
        |> Enum.take(12),
      recent_command_failures:
        context
        |> Map.get(:command_results, [])
        |> Enum.filter(&command_failure?/1)
        |> Enum.take(-5)
        |> Enum.map(&command_failure_summary/1),
      changed_files:
        context
        |> Map.get(:changed_files, [])
        |> List.wrap()
        |> Enum.take(-20),
      objective_status: scorecard_status(scorecard)
    }
  end

  defp repair_attempt_summary(%RepairAttempt{} = attempt) do
    %{
      iteration: attempt.iteration,
      status: attempt.status,
      child_status: attempt.child_result && attempt.child_result.status,
      changed_files: Enum.take(attempt.changed_files, 20),
      delta: Map.take(attempt.delta, [:created, :modified, :deleted]),
      error: error_summary(attempt.error)
    }
  end

  defp blocking_acceptance_summaries(nil), do: []

  defp blocking_acceptance_summaries(%WorkflowScorecard{} = scorecard) do
    scorecard.acceptance_results
    |> WorkflowScorecard.blocking_acceptance_results()
    |> Enum.map(&acceptance_summary/1)
  end

  defp acceptance_summary(result) when is_map(result) do
    %{
      id: field(result, :id),
      type: field(result, :type),
      status: field(result, :status),
      message: field(result, :message),
      metadata: field(result, :metadata) || %{}
    }
  end

  defp command_failure?(command) when is_map(command) do
    field(command, :status) in [
      :fail,
      :timeout,
      :killed,
      :blocked,
      "fail",
      "timeout",
      "killed",
      "blocked"
    ]
  end

  defp command_failure?(_command), do: false

  defp command_failure_summary(command) when is_map(command) do
    %{
      status: field(command, :status),
      argv: field(command, :argv),
      command: field(command, :command),
      cwd: field(command, :cwd),
      output_preview: field(command, :output_preview)
    }
  end

  defp error_summary(nil), do: nil

  defp error_summary(%Error{} = error) do
    %{
      kind: error.kind,
      message: error.message,
      details: error.details
    }
  end

  defp append_unique(values, value, fun) do
    (List.wrap(values) ++ [value])
    |> Enum.uniq_by(fun)
  end

  defp put_new_key(map, key, value) do
    string_key = Atom.to_string(key)

    if Map.has_key?(map, key) or Map.has_key?(map, string_key) do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp param(%ProposalNode{} = node, key),
    do: Map.get(node.params, key) || Map.get(node.params, Atom.to_string(key))

  defp check_param(%AcceptanceCheck{} = check, key),
    do: Map.get(check.params, key) || Map.get(check.params, Atom.to_string(key))

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp split_command(command) do
    command
    |> String.split(~r/\s+/, trim: true)
    |> case do
      [] -> [command]
      argv -> argv
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_value, _key), do: nil
end
