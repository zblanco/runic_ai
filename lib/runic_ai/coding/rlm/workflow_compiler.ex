defmodule RunicAI.Coding.RLM.WorkflowCompiler do
  @moduledoc """
  Compile accepted RLM coding workflow proposals into executable Runic workflows.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.CapabilityResolver
  alias RunicAI.Agent.ToolExecution
  alias RunicAI.Coding.Agent, as: StandardAgent
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.CommandResult
  alias RunicAI.Coding.RLM.Checkpoint
  alias RunicAI.Coding.RLM.ChildContract
  alias RunicAI.Coding.RLM.ChildResult
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.EditPatchSet
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.PlanPatchValidator
  alias RunicAI.Coding.RLM.Reducers
  alias RunicAI.Coding.RLM.RuntimeBudget
  alias RunicAI.Coding.RLM.VerificationGate
  alias RunicAI.Coding.RLM.WorkspaceDelta
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.Coding.RLM.WorkflowValidator
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.Ids
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.RLM.Episode
  alias RunicAI.RLM.Components.SafeCompute
  alias RunicAI.RLM.PlanPatch

  @default_model "openai:gpt-5.4-mini"
  @default_child_runtime_ms 120_000
  @child_agent_cleanup_grace_ms 5_000
  @default_child_noop_repair_attempts 1
  @default_child_patch_repair_attempts 1
  @min_default_child_runtime_ms 250
  @child_runtime_completion_reserve_ms 2_000
  @default_child_runtime_by_mode %{
    read_only: 20_000,
    explain_repo: 20_000,
    review: 20_000,
    triage_bug: 20_000,
    verify: 30_000,
    write_tests: 45_000,
    fix_ci: 45_000,
    patch: 90_000
  }

  @type compiled :: %{
          required(:workflow) => Workflow.t(),
          required(:proposal) => WorkflowProposal.t(),
          required(:validation_report) => WorkflowValidationReport.t(),
          required(:node_names) => %{String.t() => String.t()},
          required(:metadata) => map()
        }

  @spec compile(WorkflowProposal.t() | map(), CodebaseEnvironment.t(), keyword()) ::
          {:ok, compiled()} | {:error, Error.t()}
  def compile(proposal_input, %CodebaseEnvironment{} = environment, opts \\ [])
      when is_list(opts) do
    with {:ok, proposal} <- WorkflowProposal.from_input(proposal_input),
         report = WorkflowValidator.validate(proposal, validation_opts(environment, opts)),
         true <- WorkflowValidationReport.accepted?(report) || {:error, report} do
      {:ok, compile_accepted(proposal, report, environment, opts)}
    else
      {:error, %WorkflowValidationReport{} = report} ->
        {:error,
         Error.validation("cannot compile rejected RLM coding workflow proposal",
           source: __MODULE__,
           details: %{report: report}
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @spec compile!(WorkflowProposal.t() | map(), CodebaseEnvironment.t(), keyword()) :: compiled()
  def compile!(proposal_input, %CodebaseEnvironment{} = environment, opts \\ []) do
    case compile(proposal_input, environment, opts) do
      {:ok, compiled} -> compiled
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec run(WorkflowProposal.t() | map(), CodebaseEnvironment.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(proposal_input, %CodebaseEnvironment{} = environment, input \\ %{}, opts \\ [])
      when is_map(input) and is_list(opts) do
    opts = maybe_put_run_deadline(opts)

    with {:ok, compiled} <- compile(proposal_input, environment, opts),
         {:ok, context} <- execute_once(compiled.proposal, environment, input, opts) do
      {:ok,
       %{
         proposal: compiled.proposal,
         validation_report: compiled.validation_report,
         workflow: compiled.workflow,
         context: context,
         output: output_from_context(context, compiled.proposal),
         trace: Map.get(context, :trace, []),
         episodes: Map.get(context, :episodes, [])
       }}
    end
  end

  defp maybe_put_run_deadline(opts) do
    case {Keyword.get(opts, :run_deadline_ms), Keyword.get(opts, :max_runtime_ms)} do
      {nil, max_runtime_ms} when is_integer(max_runtime_ms) and max_runtime_ms > 0 ->
        Keyword.put(opts, :run_deadline_ms, System.monotonic_time(:millisecond) + max_runtime_ms)

      _other ->
        opts
    end
  end

  defp execute_once(
         %WorkflowProposal{} = proposal,
         %CodebaseEnvironment{} = environment,
         input,
         opts
       ) do
    context = initial_context(input, proposal, environment, opts)

    proposal.nodes
    |> topological_order(proposal.edges)
    |> Enum.reduce_while({:ok, context}, fn node, {:ok, context} ->
      case execute_node(node, context, opts) do
        {:ok, context} -> {:cont, {:ok, context}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec result(compiled(), Workflow.t()) :: map()
  def result(compiled, %Workflow{} = workflow) do
    output_name = Map.get(compiled.node_names, output_node_id(compiled.proposal))
    context = workflow |> Workflow.raw_productions(output_name) |> List.last()

    %{
      proposal: compiled.proposal,
      validation_report: compiled.validation_report,
      workflow: workflow,
      context: context,
      output: output_from_context(context, compiled.proposal),
      trace: Map.get(context || %{}, :trace, []),
      episodes: Map.get(context || %{}, :episodes, [])
    }
  end

  defp compile_accepted(%WorkflowProposal{} = proposal, report, environment, opts) do
    node_names =
      proposal.nodes
      |> Enum.with_index(1)
      |> Map.new(fn {node, index} -> {node.id, "rlm_node_#{index}_#{safe_name(node.id)}"} end)

    input_name = "rlm_coding_input"

    input_step =
      Runic.step(
        fn input ->
          initial_context(input, proposal, environment, opts)
        end,
        name: input_name
      )

    compile_opts = Keyword.put(opts, :node_names, node_names)

    workflow =
      proposal.nodes
      |> topological_order(proposal.edges)
      |> Enum.reduce(
        Workflow.new(name: "rlm_coding_workflow:#{proposal.id}") |> Workflow.add(input_step),
        fn node, workflow ->
          parents = parent_ids(node.id, proposal.edges)

          to =
            if parents == [], do: input_name, else: Enum.map(parents, &Map.fetch!(node_names, &1))

          Workflow.add(workflow, node_step(node, length(List.wrap(to)), compile_opts), to: to)
        end
      )

    %{
      workflow: workflow,
      proposal: proposal,
      validation_report: report,
      node_names: node_names,
      metadata: %{
        proposal_id: proposal.id,
        source_count: map_size(environment.source_index.refs_by_id)
      }
    }
  end

  defp node_step(node, 1, opts) do
    Runic.step(fn context -> execute_node!(node, merge_contexts([context]), opts) end,
      name: Keyword.fetch!(opts, :node_names) |> Map.fetch!(node.id)
    )
  end

  defp node_step(node, 2, opts) do
    Runic.step(fn left, right -> execute_node!(node, merge_contexts([left, right]), opts) end,
      name: Keyword.fetch!(opts, :node_names) |> Map.fetch!(node.id)
    )
  end

  defp node_step(node, 3, opts) do
    Runic.step(fn a, b, c -> execute_node!(node, merge_contexts([a, b, c]), opts) end,
      name: Keyword.fetch!(opts, :node_names) |> Map.fetch!(node.id)
    )
  end

  defp node_step(node, _parent_count, opts) do
    Runic.step(fn a, b, c, d -> execute_node!(node, merge_contexts([a, b, c, d]), opts) end,
      name: Keyword.fetch!(opts, :node_names) |> Map.fetch!(node.id)
    )
  end

  defp execute_node!(node, context, opts) do
    case execute_node(node, context, opts) do
      {:ok, context} -> context
      {:error, %Error{} = error} -> raise ArgumentError, error.message
    end
  end

  defp execute_node(node, context, opts) do
    emit_node_stage(opts, :node_started, :running, %{
      node_id: node.id,
      kind: node.kind,
      status: :started
    })

    emit_node_budget_context(opts, node)

    context =
      checkpoint_context(context, :node_started, %{
        node_id: node.id,
        kind: node.kind,
        status: :started
      })

    with {:ok, output, episode} <- dispatch_node(node, context, opts) do
      context =
        context
        |> put_in([:outputs, node.id], output)
        |> record_special_output(node, output)
        |> update_in([:episodes], &append_episode(&1, episode))
        |> update_in(
          [:trace],
          &append_trace(&1, %{node_id: node.id, kind: node.kind, status: episode.status})
        )
        |> checkpoint_context(:node_completed, %{
          node_id: node.id,
          kind: node.kind,
          status: episode.status,
          output: output
        })

      emit_node_stage(opts, :node_completed, normalize_event_status(episode.status), %{
        node_id: node.id,
        kind: node.kind,
        status: episode.status,
        output: summarize_node_output(output)
      })

      {:ok, context}
    else
      {:error, %Error{} = error} ->
        _ref =
          checkpoint_context(context, :node_failed, %{
            node_id: node.id,
            kind: node.kind,
            status: :failed,
            error: error
          })

        emit_node_stage(opts, :node_failed, :error, %{
          node_id: node.id,
          kind: node.kind,
          status: :failed,
          error: error_summary(error)
        })

        {:error, error}
    end
  end

  defp dispatch_node(%{kind: :deterministic_step} = node, context, _opts) do
    output =
      case param(node, :action) do
        "source_summary" -> CodebaseEnvironment.source_summaries(context.codebase_environment)
        "workspace_summary" -> Tools.list_dir(context.workspace, %{path: ".", limit: 100})
        "constant" -> param(node, :value)
        "merge" -> parent_outputs(node, context)
        _ -> parent_outputs(node, context)
      end

    ok_episode(node, output)
  end

  defp dispatch_node(%{kind: :tool} = node, context, opts) do
    name = param(node, :tool) || param(node, :name)
    args = tool_args(name, param(node, :args) || %{}, node, context)
    registry = Keyword.get_lazy(opts, :registry, fn -> default_registry(context, opts) end)

    with {:ok, output} <-
           ToolExecution.execute(registry, name, args,
             capability_profile: Keyword.get(opts, :capability_profile),
             review_decider: Keyword.get(opts, :review_decider),
             run_id: get_in(context, [:metadata, :run_id]),
             session_id: Keyword.get(opts, :session_id),
             context: %{workspace: context.workspace, node_id: node.id, params: node.params}
           ) do
      ok_episode(node, output)
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp dispatch_node(%{kind: :computing} = node, context, opts) do
    input =
      case parent_outputs(node, context) do
        [single] -> single
        outputs -> outputs
      end

    family = computing_family(node)
    params = Map.delete(node.params || %{}, :family) |> Map.delete("family")

    case SafeCompute.run(family, input, params,
           workspace: context.workspace,
           max_tier: Keyword.get(opts, :max_generated_function_tier, :tier1)
         ) do
      {:ok, output} -> ok_episode(node, output)
      {:error, error} -> {:error, error}
    end
  end

  defp dispatch_node(%{kind: :llm_leaf} = node, context, opts) do
    prompt = leaf_prompt(node, context)
    model = Keyword.get(opts, :model, @default_model)

    llm_opts =
      opts
      |> Keyword.get(:llm_opts, [])
      |> maybe_put_client(Keyword.get(opts, :client))

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} -> ok_episode(node, Result.text(result))
      {:retry, error} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  defp dispatch_node(%{kind: :reducer} = node, context, _opts) do
    reducer = param(node, :reducer) || :report
    output = Reducers.reduce(reducer, parent_outputs(node, context), reducer_opts(node))
    ok_episode(node, output)
  end

  defp dispatch_node(%{kind: :agent} = node, context, opts) do
    mode = param(node, :mode) || "read_only"
    task = param(node, :task) || context.proposal.objective
    agent_opts = agent_opts(mode, opts)

    with {:ok, workspace} <- agent_workspace(node, context) do
      task = scoped_agent_task(task, workspace, context)
      child_timeout_ms = child_runtime_timeout(node, agent_opts, context, opts)
      agent_opts = maybe_put_child_runtime(agent_opts, child_timeout_ms)
      agent_opts = maybe_put_child_live_event_sink(agent_opts, node, opts)

      contract =
        node
        |> param(:contract)
        |> case do
          nil -> param(node, :child_contract)
          value -> value
        end

      child_contract =
        case ChildContract.from_input(contract) do
          {:ok, value} -> value
          {:error, _error} -> nil
        end

      child_result =
        case run_standard_agent_child(
               mode,
               workspace,
               task,
               agent_opts,
               node,
               child_timeout_ms,
               opts
             ) do
          {:ok, summary} ->
            ChildResult.from_agent_summary(summary, child_contract, id: node.id)

          {:error, %Error{} = error} ->
            failed_child_result(node, error)
        end

      episode(node, child_result, ChildResult.episode_status(child_result))
    end
  end

  defp dispatch_node(%{kind: :edit} = node, context, opts) do
    patch_set =
      param(node, :patch_set) ||
        %{
          objective: param(node, :objective) || context.proposal.objective,
          operations: List.wrap(param(node, :operations)),
          expected_changed_files: List.wrap(param(node, :expected_changed_files)),
          target_paths: List.wrap(param(node, :target_paths)),
          metadata: param(node, :metadata) || %{}
        }

    with {:ok, patch_set} <- maybe_review_rlm_node(:edit, node, patch_set, context, opts),
         {:ok, output} <- EditPatchSet.apply(context.workspace, patch_set) do
      status = if output.status == :ok, do: :satisfied, else: :failed
      episode(node, output, status)
    end
  end

  defp dispatch_node(%{kind: :verification_gate} = node, context, opts) do
    contract =
      verification_contract(node, context)

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
      |> Map.put(:parent_outputs, parent_outputs(node, context))

    with {:ok, output} <-
           VerificationGate.run(
             context.workspace,
             contract,
             verification_context,
             Keyword.get(opts, :verification_gate_opts, [])
           ) do
      status = if output.status == :objective_satisfied, do: :satisfied, else: :partial
      episode(node, output, status)
    end
  end

  defp dispatch_node(%{kind: :workflow_patch} = node, _context, opts) do
    patch = param(node, :patch)

    if match?(%PlanPatch{}, patch) do
      report = PlanPatchValidator.validate(patch, nil, Keyword.get(opts, :plan_patch_opts, []))
      ok_episode(node, report)
    else
      ok_episode(node, %{status: :skipped, reason: :no_plan_patch})
    end
  end

  defp dispatch_node(%{kind: :review_gate} = node, context, _opts) do
    ok_episode(node, %{reviewed_outputs: parent_outputs(node, context), status: :allowed})
  end

  defp dispatch_node(%{kind: :command} = node, context, opts) do
    policy =
      Keyword.get_lazy(opts, :command_policy, fn ->
        rlm_command_policy(context, opts,
          allowed_commands: ["mix", "git"],
          allow_shell: false,
          allow_just_bash: false
        )
      end)

    args = command_args(node)

    with {:ok, args} <- maybe_review_rlm_node(:command, node, args, context, opts) do
      Tools.run_command(context.workspace, args, policy,
        event_sink: Keyword.get(opts, :event_sink) || Keyword.get(opts, :stage_sink)
      )
    end
    |> case do
      {:ok, output} -> ok_episode(node, output)
      {:error, error} -> {:error, error}
    end
  end

  defp dispatch_node(%{kind: :script} = node, context, opts) do
    if script_allowed?(opts) do
      policy =
        Keyword.get_lazy(opts, :script_command_policy, fn ->
          rlm_command_policy(context, opts,
            allowed_commands: ["just_bash"],
            allow_shell: false,
            allow_just_bash: true,
            max_output_bytes: 16_384
          )
        end)

      args = %{
        sandbox: param(node, :sandbox) || script_sandbox_name(opts),
        backend: param(node, :backend) || script_backend(opts),
        runtime: param(node, :runtime) || script_runtime(opts),
        code: param(node, :script) || "",
        timeout_ms: param(node, :timeout_ms) || 10_000,
        max_output_bytes: param(node, :max_output_bytes) || 16_384,
        network: param(node, :network) || script_network(opts),
        sandbox_cwd: param(node, :sandbox_cwd) || "/workspace"
      }

      with {:ok, args} <- maybe_review_rlm_node(:script, node, args, context, opts) do
        Tools.execute_code(context.workspace, args, policy,
          sandbox_opts: script_sandbox_opts(opts),
          event_sink: Keyword.get(opts, :event_sink) || Keyword.get(opts, :stage_sink)
        )
      end
      |> case do
        {:ok, output} -> ok_episode(node, output)
        {:error, error} -> {:error, error}
      end
    else
      ok_episode(node, %{status: :blocked, reason: :script_execution_requires_opt_in})
    end
  end

  defp ok_episode(node, output), do: episode(node, output, episode_status(output))

  defp episode_status(%CommandResult{status: :pass}), do: :satisfied

  defp episode_status(%CommandResult{status: status}) when status in [:fail, :timeout, :blocked],
    do: :partial

  defp episode_status(_output), do: :satisfied

  defp episode(node, output, status) do
    episode =
      Episode.new!(status, output,
        id: "episode:#{node.id}",
        parent_node_id: node.id,
        worker_id: "rlm-coding:#{node.kind}",
        artifacts: List.wrap(output),
        provenance: node.provenance,
        metadata: %{node_kind: node.kind}
      )

    {:ok, output, episode}
  end

  defp record_special_output(context, %{kind: :agent}, %ChildResult{} = child_result) do
    context
    |> update_in(
      [:child_results],
      &append_unique(&1, child_result, fn result -> result.id end)
    )
    |> maybe_record_child_review_request(child_result)
  end

  defp record_special_output(context, %{kind: :edit}, %{changed_paths: changed_paths} = output) do
    context
    |> update_in([:changed_files], &Enum.uniq(List.wrap(&1) ++ changed_paths))
    |> update_in(
      [:artifacts],
      fn artifacts -> append_unique(artifacts, output, &artifact_identity/1) end
    )
  end

  defp record_special_output(context, %{kind: :verification_gate}, output) do
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
  end

  defp record_special_output(context, %{kind: :command} = node, output) do
    context
    |> update_in([:command_results], &Enum.uniq(List.wrap(&1) ++ [output]))
    |> maybe_record_runtime_smoke(node, output)
  end

  defp record_special_output(context, %{kind: :deterministic_step} = node, output) do
    context
    |> maybe_record_objective_contract(node, output)
    |> update_in([:artifacts], &Enum.uniq(List.wrap(&1) ++ List.wrap(output)))
  end

  defp record_special_output(context, _node, output) do
    update_in(context, [:artifacts], &Enum.uniq(List.wrap(&1) ++ List.wrap(output)))
  end

  defp maybe_record_child_review_request(context, %ChildResult{} = child_result) do
    case map_value(child_result.metadata, :review_request) do
      nil ->
        context

      review_request ->
        context
        |> Map.put(:latest_review_request, review_request)
        |> update_in(
          [:review_requests],
          &append_unique(&1, review_request, fn request -> map_value(request, :resume_key) end)
        )
    end
  end

  defp maybe_record_runtime_smoke(context, node, output) do
    if runtime_smoke_node?(node) do
      update_in(
        context,
        [:runtime_smokes],
        &append_latest(&1, runtime_smoke_observation(node, output), fn smoke -> smoke.id end)
      )
    else
      context
    end
  end

  defp runtime_smoke_node?(node) do
    metadata = node_metadata(node)

    node_id(node) == "runtime_smoke" or
      metadata_value(metadata, :purpose) in [:runtime_smoke, "runtime_smoke"] or
      metadata_value(metadata, :runtime_smoke?) in [true, "true"]
  end

  defp runtime_smoke_observation(node, output) do
    metadata = node_metadata(node)

    %{
      id: metadata_value(metadata, :smoke_id) || metadata_value(metadata, :id) || node_id(node),
      status: command_status(output),
      argv: map_value(output, :argv),
      command: map_value(output, :command),
      cwd: map_value(output, :cwd),
      output_preview: map_value(output, :output_preview) || map_value(output, :output),
      source_node_id: node_id(node)
    }
  end

  defp command_status(output) do
    case map_value(output, :status) do
      :pass -> :pass
      "pass" -> :pass
      :ok -> :pass
      "ok" -> :pass
      other -> other || :fail
    end
  end

  defp node_metadata(node) do
    args =
      node
      |> param(:args)
      |> normalize_map()

    %{}
    |> Map.merge(normalize_map(Map.get(node, :metadata, %{})))
    |> Map.merge(normalize_map(map_value(args, :metadata)))
    |> Map.merge(normalize_map(param(node, :metadata)))
  end

  defp node_id(node), do: Map.get(node, :id) || Map.get(node, "id")

  defp metadata_value(metadata, key), do: map_value(metadata, key)

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_map, _key), do: nil

  defp maybe_record_objective_contract(context, node, output) do
    if objective_contract_output?(node, output) do
      case ObjectiveContract.from_input(output) do
        {:ok, %ObjectiveContract{} = contract} -> Map.put(context, :objective_contract, contract)
        {:error, _error} -> context
      end
    else
      context
    end
  end

  defp objective_contract_output?(node, output) do
    node.id in ["acceptance_contract", "objective_contract"] or
      (is_map(output) and not is_nil(map_field(output, :objective)) and
         is_list(map_field(output, :requirements)))
  end

  defp map_field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp append_unique(values, value, fun) do
    (List.wrap(values) ++ [value])
    |> Enum.uniq_by(fun)
  end

  defp append_latest(values, value, fun) do
    key = fun.(value)

    values
    |> List.wrap()
    |> Enum.reject(&(fun.(&1) == key))
    |> Kernel.++([value])
  end

  defp artifact_identity(%{id: id}) when not is_nil(id), do: inspect(id)
  defp artifact_identity(%{"id" => id}) when not is_nil(id), do: inspect(id)
  defp artifact_identity(artifact), do: inspect(artifact)

  defp acceptance_results(output), do: get_in(output, [:evaluation, :results]) || []

  defp initial_context(input, proposal, environment, opts) do
    %{
      input: input,
      proposal: proposal,
      workspace: environment.workspace,
      codebase_environment: environment,
      outputs: %{},
      episodes: [],
      trace: [],
      child_results: [],
      changed_files: [],
      command_results: [],
      runtime_smokes: [],
      verification_observations: [],
      scorecards: [],
      repair_needs: [],
      objective_contract: nil,
      objective_judgements: [],
      objective_evidence_summaries: [],
      artifacts: [],
      checkpoint_refs: [],
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp merge_contexts(contexts) do
    contexts
    |> Enum.flat_map(fn
      values when is_list(values) -> values
      value -> [value]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(fn context, acc ->
      acc
      |> update_in([:outputs], &Map.merge(&1 || %{}, context.outputs || %{}))
      |> update_in([:episodes], &Enum.uniq((&1 || []) ++ (context.episodes || [])))
      |> update_in([:trace], &Enum.uniq((&1 || []) ++ (context.trace || [])))
      |> update_in([:child_results], &Enum.uniq((&1 || []) ++ (context.child_results || [])))
      |> update_in([:changed_files], &Enum.uniq((&1 || []) ++ (context.changed_files || [])))
      |> update_in([:command_results], &Enum.uniq((&1 || []) ++ (context.command_results || [])))
      |> update_in([:runtime_smokes], &Enum.uniq((&1 || []) ++ (context.runtime_smokes || [])))
      |> update_in(
        [:verification_observations],
        &Enum.uniq((&1 || []) ++ (context.verification_observations || []))
      )
      |> update_in([:scorecards], &Enum.uniq((&1 || []) ++ (context.scorecards || [])))
      |> update_in([:repair_needs], &Enum.uniq((&1 || []) ++ (context.repair_needs || [])))
      |> update_in([:artifacts], &Enum.uniq((&1 || []) ++ (context.artifacts || [])))
      |> update_in(
        [:checkpoint_refs],
        &Enum.uniq((&1 || []) ++ (context.checkpoint_refs || []))
      )
    end)
  end

  defp checkpoint_context(context, stage, payload) do
    ref =
      Checkpoint.record_best_effort(
        context.workspace.persistence,
        stage,
        Map.merge(payload, %{
          proposal_id: context.proposal.id,
          output_ids: Map.keys(context.outputs || %{})
        }),
        run_id: get_in(context, [:metadata, :run_id]),
        proposal_id: context.proposal.id,
        node_id: Map.get(payload, :node_id)
      )

    update_in(context, [:checkpoint_refs], fn refs ->
      refs = List.wrap(refs)
      if is_binary(ref), do: Enum.uniq(refs ++ [ref]), else: refs
    end)
  end

  defp append_episode(episodes, episode) do
    episodes
    |> Kernel.++([episode])
    |> Enum.uniq_by(& &1.id)
  end

  defp append_trace(trace, event) do
    trace
    |> Kernel.++([event])
    |> Enum.uniq_by(&{&1.node_id, &1.kind, &1.status})
  end

  defp parent_outputs(node, context) do
    node.id
    |> parent_ids(context.proposal.edges)
    |> Enum.map(&Map.get(context.outputs, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp leaf_prompt(node, context) do
    """
    Objective:
    #{context.proposal.objective}

    Node:
    #{node.id}

    Instructions:
    #{param(node, :prompt) || "Analyze the available parent outputs and source summaries."}

    Sources:
    #{Jason.encode!(CodebaseEnvironment.source_summaries(context.codebase_environment, 20))}

    Parent outputs:
    #{inspect(parent_outputs(node, context), limit: 20, printable_limit: 4_000)}
    """
  end

  defp reducer_opts(node), do: param(node, :opts) || []

  defp default_registry(context, opts) do
    if CapabilityResolver.requested?(opts) do
      CapabilityResolver.resolve!(context.workspace,
        agent: :rlm,
        mode: Keyword.get(opts, :mode, :verify),
        profile: Keyword.get(opts, :profile),
        toolsets: Keyword.get(opts, :toolsets, []),
        disabled_tools: Keyword.get(opts, :disabled_tools, []),
        tool_config: Keyword.get(opts, :tool_config, %{}),
        approval: Keyword.get(opts, :approval, Keyword.get(opts, :approve)),
        write_policy: Keyword.get(opts, :write_policy),
        memory_store: Keyword.get(opts, :memory_store),
        memory_store_opts: Keyword.get(opts, :memory_store_opts),
        session_store: Keyword.get(opts, :session_store)
      ).registry
    else
      Tools.default_registry(context.workspace,
        command_policy:
          Keyword.get_lazy(opts, :command_policy, fn ->
            CommandPolicy.new!(allowed_commands: ["git", "mix"], allow_shell: false)
          end),
        memory_store: Keyword.get(opts, :memory_store),
        memory_store_opts: Keyword.get(opts, :memory_store_opts),
        session_store: Keyword.get(opts, :session_store)
      )
    end
  end

  defp rlm_command_policy(context, opts, fallback_opts) do
    if CapabilityResolver.requested?(opts) do
      CapabilityResolver.resolve!(context.workspace,
        agent: :rlm,
        mode: Keyword.get(opts, :mode, :verify),
        profile: Keyword.get(opts, :profile),
        toolsets: Keyword.get(opts, :toolsets, []),
        disabled_tools: Keyword.get(opts, :disabled_tools, []),
        tool_config: Keyword.get(opts, :tool_config, %{}),
        approval: Keyword.get(opts, :approval, Keyword.get(opts, :approve)),
        write_policy: Keyword.get(opts, :write_policy),
        memory_store: Keyword.get(opts, :memory_store),
        memory_store_opts: Keyword.get(opts, :memory_store_opts),
        session_store: Keyword.get(opts, :session_store)
      ).command_policy
    else
      CommandPolicy.new!(fallback_opts)
    end
  end

  defp script_allowed?(opts) do
    Keyword.get(opts, :allow_scripts?, false) or
      (CapabilityResolver.requested?(opts) and
         :code_execution in CapabilityResolver.enabled_toolsets(opts))
  end

  defp script_sandbox_opts(opts) do
    case Keyword.fetch(opts, :sandbox_opts) do
      {:ok, sandbox_opts} ->
        sandbox_opts

      :error ->
        sandbox_opts_from_tool_config(opts)
    end
  end

  defp sandbox_opts_from_tool_config(opts) do
    tool_config = Keyword.get(opts, :tool_config, %{})

    case config_value(tool_config, :code_execution, nil) do
      config when is_map(config) or is_list(config) ->
        [
          profile: [
            name: config |> config_value(:sandbox, :local_code) |> normalize_sandbox_atom(),
            backend: script_backend_from_config(config),
            runtimes:
              config
              |> config_value(:allowed_runtimes, config_value(config, :runtimes, [:bash]))
              |> sandbox_runtime_list(),
            isolation_level: config_value(config, :isolation_level, nil),
            policy: sandbox_policy(config),
            network: config_value(config, :network, :disabled),
            stateful?: config_value(config, :stateful?, false),
            pool: config_value(config, :pool, %{warm: 0, max: 1}),
            workspace: config_value(config, :workspace, %{mode: :copy_in, persist?: false}),
            backend_options: sandbox_backend_options(config),
            metadata: sandbox_metadata(config)
          ]
        ]

      _other ->
        []
    end
  end

  defp sandbox_policy(config) do
    case config_value(config, :isolation_minimum, nil) do
      nil -> []
      isolation_minimum -> [isolation_minimum: isolation_minimum]
    end
  end

  defp sandbox_backend_options(config) do
    config = normalize_map(config)

    nested =
      config_value(config, :backend_options, %{})
      |> normalize_map()
      |> Map.new(fn {key, value} -> {normalize_config_key(key), value} end)

    config
    |> Map.take([:image, "image", :executable, "executable", :sudo?, "sudo?"])
    |> Map.new(fn {key, value} -> {normalize_config_key(key), value} end)
    |> Map.merge(nested)
  end

  defp sandbox_metadata(config) do
    config = normalize_map(config)

    [:state_model, :transport_model, :session, :checkpoint_policy, :service_policy]
    |> Enum.reduce(%{}, fn key, acc ->
      case config_value(config, key, nil) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp normalize_config_key("image"), do: :image
  defp normalize_config_key("executable"), do: :executable
  defp normalize_config_key("sudo?"), do: :sudo?
  defp normalize_config_key(key), do: key

  defp script_sandbox_name(opts),
    do: opts |> code_execution_config_value(:sandbox, :local_code) |> normalize_sandbox_atom()

  defp script_backend(opts) do
    case Keyword.fetch(opts, :sandbox_opts) do
      {:ok, sandbox_opts} -> sandbox_backend_from_opts(sandbox_opts)
      :error -> script_backend_from_config(code_execution_config(opts))
    end
  end

  defp script_runtime(opts) do
    opts
    |> code_execution_config_value(:runtime, nil)
    |> case do
      nil ->
        :bash

      runtime ->
        runtime
    end
  end

  defp script_network(opts), do: code_execution_config_value(opts, :network, :disabled)

  defp code_execution_config_value(opts, key, default) do
    opts
    |> code_execution_config()
    |> config_value(key, default)
  end

  defp code_execution_config(opts) do
    opts
    |> Keyword.get(:tool_config, %{})
    |> config_value(:code_execution, %{})
  end

  defp script_backend_from_config(config) do
    config
    |> config_value(:backend, config_value(config, :default_backend, :just_bash))
    |> normalize_sandbox_backend()
  end

  defp sandbox_backend_from_opts(opts) when is_list(opts) do
    opts
    |> Keyword.get(:profile, [])
    |> config_value(:backend, :just_bash)
  end

  defp sandbox_backend_from_opts(_opts), do: :just_bash

  defp sandbox_runtime_list(runtimes) when is_list(runtimes), do: runtimes

  defp sandbox_runtime_list(runtimes) when is_binary(runtimes) do
    runtimes
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_existing_atom/1)
  rescue
    ArgumentError ->
      runtimes
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end

  defp sandbox_runtime_list(runtime) when is_atom(runtime), do: [runtime]
  defp sandbox_runtime_list(_runtime), do: [:bash]

  defp normalize_sandbox_atom(value) when is_atom(value), do: value

  defp normalize_sandbox_atom(value) when is_binary(value) and value != "" do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :just_bash
  end

  defp normalize_sandbox_atom(_value), do: :just_bash

  defp normalize_sandbox_backend(value) when is_atom(value), do: value

  defp normalize_sandbox_backend(value) when is_binary(value) and value != "" do
    case value do
      "just_bash" -> :just_bash
      "lua" -> :lua
      "wasmtime" -> :wasmtime
      "docker" -> :docker
      "podman" -> :podman
      "gvisor" -> :gvisor
      "vmsan" -> :vmsan
      "firecracker" -> :firecracker
      "sprites" -> :sprites
      "remote" -> :remote
      _other -> value
    end
  end

  defp normalize_sandbox_backend(value), do: value

  defp computing_family(node) do
    case param(node, :family) || param(node, :component) || param(node, :type) do
      family
      when family in [
             :collection_compute,
             :string_compute,
             :json_compute,
             :artifact_compute,
             :time_compute,
             :score_compute
           ] ->
        family

      family when is_binary(family) ->
        case String.replace(family, "-", "_") do
          "collection" -> :collection_compute
          "collection_compute" -> :collection_compute
          "string" -> :string_compute
          "string_compute" -> :string_compute
          "json" -> :json_compute
          "json_compute" -> :json_compute
          "artifact" -> :artifact_compute
          "artifact_compute" -> :artifact_compute
          "time" -> :time_compute
          "time_compute" -> :time_compute
          "score" -> :score_compute
          "score_compute" -> :score_compute
          _other -> :collection_compute
        end

      _other ->
        :collection_compute
    end
  end

  defp validation_opts(%CodebaseEnvironment{} = environment, opts) do
    opts
    |> Keyword.get(:validation_opts, [])
    |> Keyword.merge(
      mode: Keyword.get(opts, :mode, :verify),
      profile: Keyword.get(opts, :profile),
      toolsets: Keyword.get(opts, :toolsets, []),
      disabled_tools: Keyword.get(opts, :disabled_tools, []),
      tool_config: Keyword.get(opts, :tool_config, %{}),
      capability_profile: Keyword.get(opts, :capability_profile),
      workspace: environment.workspace
    )
  end

  defp maybe_review_rlm_node(kind, node, value, context, opts) do
    decider = Keyword.get(opts, :review_decider)

    cond do
      not rlm_node_review_required?(kind, value) ->
        {:ok, value}

      is_function(decider, 2) ->
        # RLM command/script/edit nodes are side-effect capable. If they reach
        # execution, the capability profile has made them visible, but HITL is
        # still the runtime boundary.
        review_rlm_node(decider, kind, node, value, context, opts)

      true ->
        {:ok, value}
    end
  end

  defp rlm_node_review_required?(:command, value) when is_map(value) do
    metadata = Map.get(value, :metadata) || Map.get(value, "metadata") || %{}

    not (Map.get(metadata, :requires_review?) == false or
           Map.get(metadata, "requires_review?") == false or Map.get(metadata, :review?) == false or
           Map.get(metadata, "review?") == false)
  end

  defp rlm_node_review_required?(_kind, _value), do: true

  defp review_rlm_node(decider, kind, node, value, context, opts) do
    safety = rlm_node_review_safety(kind, value)

    request =
      RunicAI.ReviewRequest.new!(:rlm_node_execution,
        checkpoint: :pre_tool,
        resume_key:
          "review:rlm:#{get_in(context, [:metadata, :run_id]) || Keyword.get(opts, :run_id) || System.unique_integer([:positive])}:#{node.id}:#{System.unique_integer([:positive])}",
        options: [:approve, :reject, :edit, :cancel],
        subject: %{kind: kind, node_id: node.id, value: value},
        details: %{
          kind: kind,
          node_id: node.id,
          value: value,
          reason: :gated_rlm_node,
          safe?: safety.safe?,
          risk: safety.risk
        },
        metadata: %{
          safe?: safety.safe?,
          risk: safety.risk,
          node_kind: kind,
          requires_review?: true
        }
      )

    case decider.(request, %{workspace: context.workspace, node: node, params: value}) do
      {:ok, %RunicAI.ReviewDecision{status: :approved}} ->
        {:ok, value}

      {:ok, %RunicAI.ReviewDecision{status: :edited, edited_value: edited}} ->
        {:ok, normalize_review_edit(edited, value)}

      {:ok, %RunicAI.ReviewDecision{status: status}} when status in [:rejected, :cancelled] ->
        {:error,
         Error.validation("RLM node execution denied by review",
           source: __MODULE__,
           details: %{node_id: node.id, kind: kind, decision_status: status}
         )}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp normalize_review_edit(edited, _original) when is_map(edited), do: edited

  defp normalize_review_edit(edited, original) when is_binary(edited) do
    case Jason.decode(edited) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> original
    end
  end

  defp normalize_review_edit(_edited, original), do: original

  defp rlm_node_review_safety(:edit, %EditPatchSet{}), do: %{safe?: false, risk: :medium}
  defp rlm_node_review_safety(:edit, _value), do: %{safe?: false, risk: :medium}

  defp rlm_node_review_safety(:command, value) when is_map(value) do
    metadata = Map.get(value, :metadata) || Map.get(value, "metadata") || %{}

    if Map.get(metadata, :safe?) == true or Map.get(metadata, "safe?") == true do
      %{safe?: true, risk: Map.get(metadata, :risk) || Map.get(metadata, "risk") || :low}
    else
      %{safe?: false, risk: :medium}
    end
  end

  defp rlm_node_review_safety(_kind, _value), do: %{safe?: false, risk: :medium}

  defp tool_args("read_many", args, node, context) do
    paths = Map.get(args, :paths) || Map.get(args, "paths")

    if paths in [nil, []] do
      Map.put(args, :paths, discovered_paths(node, context))
    else
      args
    end
  end

  defp tool_args("read_file", args, node, context) do
    path = Map.get(args, :path) || Map.get(args, "path")

    if path in [nil, ""] do
      case discovered_paths(node, context) do
        [path | _rest] -> Map.put(args, :path, path)
        [] -> args
      end
    else
      args
    end
  end

  defp tool_args(_name, args, _node, _context), do: args

  defp discovered_paths(node, context) do
    node
    |> parent_outputs(context)
    |> Enum.flat_map(fn
      %{files: files} when is_list(files) ->
        Enum.map(files, &Map.get(&1, :path))

      %{"files" => files} when is_list(files) ->
        Enum.map(files, &Map.get(&1, "path"))

      %{entries: entries} when is_list(entries) ->
        Enum.map(entries, &(Map.get(&1, :path) || Map.get(&1, :name)))

      _other ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(20)
  end

  defp agent_opts(_mode, opts) do
    opts
    |> Keyword.get(:agent_opts, [])
    |> Keyword.merge(
      model: Keyword.get(opts, :model, @default_model),
      client: Keyword.get(opts, :client),
      review_gates?: Keyword.get(opts, :agent_review_gates?, true)
    )
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_put_child_runtime(agent_opts, nil), do: agent_opts
  defp maybe_put_child_runtime(agent_opts, :infinity), do: agent_opts

  defp maybe_put_child_runtime(agent_opts, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: Keyword.put_new(agent_opts, :max_runtime_ms, timeout_ms)

  defp maybe_put_child_live_event_sink(agent_opts, node, opts) do
    if child_event_sink_enabled?(opts) do
      child_sink = child_live_event_sink(node, opts)

      agent_opts
      |> put_or_compose_keyword_event_sink(:event_sink, child_sink)
      |> maybe_put_child_codex_live_event_sink(child_sink)
    else
      agent_opts
    end
  end

  defp maybe_put_child_codex_live_event_sink(agent_opts, child_sink) do
    if codex_child_client?(agent_opts) do
      Keyword.update(
        agent_opts,
        :llm_opts,
        [event_sink: child_sink],
        &put_or_compose_keyword_event_sink(&1, :event_sink, child_sink)
      )
    else
      agent_opts
    end
  end

  defp codex_child_client?(agent_opts) do
    Keyword.get(agent_opts, :client) in [:codex, RunicAI.Coding.Codex.Client] or
      Keyword.get(agent_opts, :client_backend) == :codex or
      Keyword.get(agent_opts, :codex?, false)
  end

  defp child_event_sink_enabled?(opts) do
    sink = Keyword.get(opts, :event_sink) || Keyword.get(opts, :stage_sink)
    is_function(sink, 1)
  end

  defp put_or_compose_keyword_event_sink(opts, key, child_sink) do
    case Keyword.get(opts, key) do
      existing when is_function(existing, 1) ->
        Keyword.put(opts, key, fn event ->
          safe_call_event_sink(existing, event)
          safe_call_event_sink(child_sink, event)
        end)

      _other ->
        Keyword.put(opts, key, child_sink)
    end
  end

  defp child_live_event_sink(node, opts) do
    fn event ->
      emit_node_stage(opts, :child_agent_event, child_trace_event_status(event), %{
        node_id: node.id,
        kind: node.kind,
        live?: true,
        child_event: summarize_child_event(event)
      })
    end
  end

  defp safe_call_event_sink(sink, event) do
    sink.(event)
  rescue
    _exception -> :ok
  end

  defp call_standard_agent(mode, workspace, task, opts) when mode in ["read_only", :read_only],
    do: StandardAgent.read_only(workspace, task, opts)

  defp call_standard_agent(mode, workspace, task, opts) when mode in ["patch", :patch],
    do: StandardAgent.patch(workspace, task, opts)

  defp call_standard_agent(mode, workspace, task, opts) when mode in ["verify", :verify],
    do: StandardAgent.verify(workspace, task, opts)

  defp call_standard_agent(_mode, workspace, task, opts),
    do: StandardAgent.read_only(workspace, task, opts)

  defp run_standard_agent_child(mode, workspace, task, agent_opts, node, child_timeout_ms, opts) do
    :ok =
      emit_node_stage(opts, :child_agent_started, :running, %{
        node_id: node.id,
        kind: node.kind,
        mode: mode,
        timeout_ms: child_timeout_ms,
        workspace_root: workspace.root
      })

    RuntimeBudget.run(
      fn ->
        started_ms = System.monotonic_time(:millisecond)
        before_snapshot = WorkspaceDelta.snapshot(workspace, child_workspace_delta_opts(opts))

        workflow =
          run_standard_agent_child_attempt(mode, workspace, task, agent_opts, node, opts)

        after_snapshot = WorkspaceDelta.snapshot(workspace, child_workspace_delta_opts(opts))
        delta = WorkspaceDelta.diff(before_snapshot, after_snapshot)

        {workflow, delta, patch_repair_attempts} =
          maybe_repair_patch_child(
            workflow,
            delta,
            mode,
            workspace,
            task,
            agent_opts,
            node,
            opts
          )

        {workflow, delta, noop_repair_attempts} =
          maybe_repair_noop_child(
            workflow,
            delta,
            mode,
            workspace,
            task,
            agent_opts,
            node,
            opts
          )

        elapsed_ms = System.monotonic_time(:millisecond) - started_ms
        forward_child_agent_events(opts, node, workflow)

        if child_elapsed_timeout?(child_timeout_ms, elapsed_ms) do
          child_timeout_error(node, mode, workspace, task, child_timeout_ms)
        else
          summary =
            workflow
            |> StandardAgent.summary()
            |> merge_summary_changed_files(WorkspaceDelta.changed_paths(delta))
            |> maybe_put_child_noop_repair_attempts(noop_repair_attempts)
            |> maybe_put_child_patch_repair_attempts(patch_repair_attempts)
            |> maybe_put_latest_review_request(StandardAgent.latest_review_request(workflow))

          emit_node_stage(opts, :child_agent_completed, :ok, %{
            node_id: node.id,
            kind: node.kind,
            mode: mode,
            elapsed_ms: elapsed_ms,
            changed_files: Map.get(summary, :changed_files, []),
            tools_used: Map.get(summary, :tools_used, []),
            objective_status: Map.get(summary, :objective_status),
            child_noop_repair_attempts: noop_repair_attempts,
            child_patch_repair_attempts: patch_repair_attempts
          })

          {:ok, summary}
        end
      end,
      timeout_ms: child_wrapper_timeout_ms(child_timeout_ms),
      tick_ms: Keyword.get(opts, :child_progress_tick_ms, 5_000),
      progress_sink: child_progress_sink(opts, node, mode, workspace),
      stage: :workflow_child_agent,
      objective: task,
      details: %{
        node_id: node.id,
        mode: mode,
        workspace_root: workspace.root
      }
    )
  end

  defp run_standard_agent_child_attempt(mode, workspace, task, agent_opts, node, opts) do
    mode
    |> call_standard_agent(workspace, task, agent_opts)
    |> maybe_auto_review_child_workflow(node, mode, workspace, task, opts)
  end

  defp maybe_repair_patch_child(workflow, delta, mode, workspace, task, agent_opts, node, opts) do
    if repair_patch_child?(workflow, delta, mode, opts) do
      repair_patch_child(workflow, delta, mode, workspace, task, agent_opts, node, opts)
    else
      {workflow, delta, 0}
    end
  end

  defp repair_patch_child(workflow, delta, mode, workspace, task, agent_opts, node, opts) do
    attempts = child_patch_repair_attempts(opts)

    Enum.reduce_while(1..attempts, {workflow, delta, 0}, fn attempt,
                                                            {current_workflow, current_delta,
                                                             count} ->
      if repair_patch_child?(current_workflow, current_delta, mode, opts) do
        patch_failure = failed_patch_summary(current_workflow)

        emit_node_stage(opts, :child_patch_repair_started, :running, %{
          node_id: node.id,
          kind: node.kind,
          mode: mode,
          attempt: attempt,
          reason: :apply_patch_failed,
          diagnostics: patch_failure_diagnostics(patch_failure)
        })

        before_snapshot = WorkspaceDelta.snapshot(workspace, child_workspace_delta_opts(opts))

        repair_task =
          child_patch_repair_task(task, current_workflow, node, patch_failure)

        repair_workflow =
          run_standard_agent_child_attempt(mode, workspace, repair_task, agent_opts, node, opts)

        after_snapshot = WorkspaceDelta.snapshot(workspace, child_workspace_delta_opts(opts))
        repair_delta = WorkspaceDelta.diff(before_snapshot, after_snapshot)
        merged_delta = merge_workspace_delta(current_delta, repair_delta)
        changed_files = WorkspaceDelta.changed_paths(repair_delta)
        repaired? = changed_files != [] and is_nil(failed_patch_summary(repair_workflow))

        emit_node_stage(opts, :child_patch_repair_completed, :ok, %{
          node_id: node.id,
          kind: node.kind,
          mode: mode,
          attempt: attempt,
          changed_files: changed_files,
          repaired?: repaired?
        })

        if repaired? do
          {:halt, {repair_workflow, merged_delta, count + 1}}
        else
          {:cont, {repair_workflow, merged_delta, count + 1}}
        end
      else
        {:halt, {current_workflow, current_delta, count}}
      end
    end)
  end

  defp repair_patch_child?(workflow, delta, mode, opts) do
    child_patch_repair_enabled?(mode, opts) and
      WorkspaceDelta.changed_paths(delta) == [] and
      is_nil(StandardAgent.latest_review_request(workflow)) and
      not is_nil(failed_patch_summary(workflow))
  end

  defp child_patch_repair_enabled?(mode, opts) when mode in [:patch, "patch"] do
    child_patch_repair_attempts(opts) > 0
  end

  defp child_patch_repair_enabled?(_mode, _opts), do: false

  defp child_patch_repair_attempts(opts) do
    opts
    |> Keyword.get(:child_patch_repair_attempts, @default_child_patch_repair_attempts)
    |> case do
      attempts when is_integer(attempts) and attempts >= 0 -> attempts
      _other -> @default_child_patch_repair_attempts
    end
  end

  defp failed_patch_summary(workflow) do
    workflow
    |> StandardAgent.summary()
    |> Map.get(:patches, [])
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find(&failed_patch_summary?/1)
  end

  defp failed_patch_summary?(patch) when is_map(patch) do
    patch_status(patch) in [:error, "error"] or patch_failure_diagnostics(patch) != []
  end

  defp failed_patch_summary?(_patch), do: false

  defp patch_status(patch) when is_map(patch) do
    Map.get(patch, :status, Map.get(patch, "status"))
  end

  defp patch_failure_diagnostics(patch) when is_map(patch) do
    patch
    |> Map.get(:diagnostics, Map.get(patch, "diagnostics", []))
    |> List.wrap()
    |> Enum.take(5)
  end

  defp patch_failure_diagnostics(_patch), do: []

  defp child_patch_repair_task(task, workflow, node, patch_failure) do
    summary = StandardAgent.summary(workflow)

    """
    The previous patch-mode child attempt for node #{node.id} called apply_patch, but the patch failed.

    Retry the same objective now with a valid apply_patch call:
    - Use the apply_patch tool schema exactly: operations is a list of create, update, delete, or move operations.
    - For creating a file, use %{op: "create", path: "relative/path", content: "..."}.
    - For updating an existing file, use %{op: "update", path: "relative/path", content: "..."}.
    - Do not repeat the failed operation shape. Stop only after changed files exist, a review request is pending, or a concrete blocking error prevents edits.

    Original task:
    #{task}

    Failed patch diagnostics:
    #{inspect(patch_failure_diagnostics(patch_failure), limit: 10, printable_limit: 1_200)}

    Previous child summary:
    #{String.slice(to_string(Map.get(summary, :reply, "")), 0, 1_200)}
    """
  end

  defp maybe_repair_noop_child(workflow, delta, mode, workspace, task, agent_opts, node, opts) do
    if repair_noop_child?(workflow, delta, mode, opts) do
      repair_noop_child(workflow, delta, mode, workspace, task, agent_opts, node, opts)
    else
      {workflow, delta, 0}
    end
  end

  defp repair_noop_child(workflow, delta, mode, workspace, task, agent_opts, node, opts) do
    attempts = child_noop_repair_attempts(opts)

    Enum.reduce_while(1..attempts, {workflow, delta, 0}, fn attempt,
                                                            {current_workflow, current_delta,
                                                             count} ->
      if repair_noop_child?(current_workflow, current_delta, mode, opts) do
        emit_node_stage(opts, :child_noop_repair_started, :running, %{
          node_id: node.id,
          kind: node.kind,
          mode: mode,
          attempt: attempt,
          reason: :patch_child_no_changed_files
        })

        before_snapshot = WorkspaceDelta.snapshot(workspace, child_workspace_delta_opts(opts))

        repair_task =
          child_noop_repair_task(task, current_workflow, node)

        repair_workflow =
          run_standard_agent_child_attempt(mode, workspace, repair_task, agent_opts, node, opts)

        after_snapshot = WorkspaceDelta.snapshot(workspace, child_workspace_delta_opts(opts))
        repair_delta = WorkspaceDelta.diff(before_snapshot, after_snapshot)
        merged_delta = merge_workspace_delta(current_delta, repair_delta)
        changed_files = WorkspaceDelta.changed_paths(repair_delta)

        emit_node_stage(opts, :child_noop_repair_completed, :ok, %{
          node_id: node.id,
          kind: node.kind,
          mode: mode,
          attempt: attempt,
          changed_files: changed_files,
          repaired?: changed_files != []
        })

        if changed_files == [] do
          {:cont, {repair_workflow, merged_delta, count + 1}}
        else
          {:halt, {repair_workflow, merged_delta, count + 1}}
        end
      else
        {:halt, {current_workflow, current_delta, count}}
      end
    end)
  end

  defp repair_noop_child?(workflow, delta, mode, opts) do
    child_noop_repair_enabled?(mode, opts) and
      WorkspaceDelta.changed_paths(delta) == [] and
      is_nil(StandardAgent.latest_review_request(workflow)) and
      summary_no_changed_files?(StandardAgent.summary(workflow))
  end

  defp child_noop_repair_enabled?(mode, opts) when mode in [:patch, "patch"] do
    child_noop_repair_attempts(opts) > 0
  end

  defp child_noop_repair_enabled?(_mode, _opts), do: false

  defp child_noop_repair_attempts(opts) do
    opts
    |> Keyword.get(:child_noop_repair_attempts, @default_child_noop_repair_attempts)
    |> case do
      attempts when is_integer(attempts) and attempts >= 0 -> attempts
      _other -> @default_child_noop_repair_attempts
    end
  end

  defp child_noop_repair_task(task, workflow, node) do
    summary = StandardAgent.summary(workflow)

    """
    The previous patch-mode child attempt for node #{node.id} made no workspace changes.

    Retry the same objective now with concrete file edits:
    - Use apply_patch for file changes.
    - If the selected workspace is empty and the task asks to create or build artifacts, create the requested files in this workspace or in an objective-named subdirectory.
    - Do not stop after inspection. Stop only after changed files exist, a review request is pending, or a concrete blocking error prevents edits.

    Original task:
    #{task}

    Previous child summary:
    #{String.slice(to_string(Map.get(summary, :reply, "")), 0, 1_200)}
    """
  end

  defp summary_no_changed_files?(summary) when is_map(summary) do
    List.wrap(Map.get(summary, :changed_files, [])) == []
  end

  defp child_workspace_delta_opts(opts) do
    [max_files: Keyword.get(opts, :child_workspace_delta_max_files, 1_000)]
  end

  defp merge_workspace_delta(left, right) do
    %{
      created: Enum.uniq(List.wrap(left.created) ++ List.wrap(right.created)) |> Enum.sort(),
      modified: Enum.uniq(List.wrap(left.modified) ++ List.wrap(right.modified)) |> Enum.sort(),
      deleted: Enum.uniq(List.wrap(left.deleted) ++ List.wrap(right.deleted)) |> Enum.sort(),
      unchanged: Enum.uniq(List.wrap(left.unchanged) ++ List.wrap(right.unchanged)) |> Enum.sort()
    }
  end

  defp merge_summary_changed_files(summary, changed_files) when is_map(summary) do
    Map.update(summary, :changed_files, List.wrap(changed_files), fn existing ->
      existing
      |> List.wrap()
      |> Kernel.++(List.wrap(changed_files))
      |> Enum.uniq()
      |> Enum.sort()
    end)
  end

  defp maybe_put_child_noop_repair_attempts(summary, 0), do: summary

  defp maybe_put_child_noop_repair_attempts(summary, attempts) when is_map(summary) do
    summary
    |> Map.put(:child_noop_repair_attempts, attempts)
    |> Map.update(:metadata, %{child_noop_repair_attempts: attempts}, fn
      metadata when is_map(metadata) -> Map.put(metadata, :child_noop_repair_attempts, attempts)
      _other -> %{child_noop_repair_attempts: attempts}
    end)
  end

  defp maybe_put_child_patch_repair_attempts(summary, 0), do: summary

  defp maybe_put_child_patch_repair_attempts(summary, attempts) when is_map(summary) do
    summary
    |> Map.put(:child_patch_repair_attempts, attempts)
    |> Map.update(:metadata, %{child_patch_repair_attempts: attempts}, fn
      metadata when is_map(metadata) -> Map.put(metadata, :child_patch_repair_attempts, attempts)
      _other -> %{child_patch_repair_attempts: attempts}
    end)
  end

  defp maybe_put_latest_review_request(summary, nil), do: summary

  defp maybe_put_latest_review_request(%{status: status} = summary, review_request)
       when status in [:review, "review"] do
    Map.put(summary, :latest_review_request, review_request)
  end

  defp maybe_put_latest_review_request(summary, _review_request), do: summary

  defp forward_child_agent_events(opts, node, workflow) do
    workflow
    |> StandardAgent.trace_events()
    |> Enum.take(-Keyword.get(opts, :child_forwarded_event_limit, 12))
    |> Enum.each(fn event ->
      emit_node_stage(opts, :child_agent_event, normalize_event_status(event.status), %{
        node_id: node.id,
        kind: node.kind,
        child_event: summarize_child_event(event)
      })
    end)
  end

  defp summarize_child_event(event) do
    %{
      kind: event.kind,
      status: event.status,
      output: summarize_child_event_output(event.output),
      metadata: event.metadata,
      observed_at: event.observed_at
    }
  end

  defp summarize_child_event_output(output) when is_binary(output) do
    String.slice(output, 0, 1_000)
  end

  defp summarize_child_event_output(output) when is_map(output) do
    output
    |> Map.take([
      :tool,
      :name,
      :status,
      :command,
      :argv,
      :cwd,
      :exit_status,
      :output_preview,
      :changed_paths,
      :diagnostics,
      "tool",
      "name",
      "status",
      "command",
      "argv",
      "cwd",
      "exit_status",
      "output_preview",
      "changed_paths",
      "diagnostics"
    ])
  end

  defp summarize_child_event_output(output),
    do: inspect(output, limit: 20, printable_limit: 1_000)

  defp child_trace_event_status(%{status: status}) when status in [:running, "running"],
    do: :running

  defp child_trace_event_status(%{status: nil}), do: :running
  defp child_trace_event_status(%{status: status}), do: normalize_event_status(status)
  defp child_trace_event_status(_event), do: :running

  defp child_wrapper_timeout_ms(nil), do: nil
  defp child_wrapper_timeout_ms(:infinity), do: :infinity

  defp child_wrapper_timeout_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms + @child_agent_cleanup_grace_ms

  defp child_elapsed_timeout?(timeout_ms, elapsed_ms)
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: elapsed_ms >= timeout_ms

  defp child_elapsed_timeout?(_timeout_ms, _elapsed_ms), do: false

  defp child_timeout_error(node, mode, workspace, task, timeout_ms) do
    {:error,
     Error.timeout("RLM runtime budget exhausted",
       source: RuntimeBudget,
       details: %{
         timeout_ms: timeout_ms,
         stage: :workflow_child_agent,
         objective: task,
         node_id: node.id,
         mode: mode,
         workspace_root: workspace.root
       }
     )}
  end

  defp maybe_auto_review_child_workflow(workflow, node, mode, workspace, task, opts) do
    case Keyword.get(opts, :review_decider) do
      decider when is_function(decider, 2) ->
        auto_review_child_workflow(
          workflow,
          node,
          mode,
          workspace,
          task,
          decider,
          opts,
          Keyword.get(opts, :child_auto_review_limit, 3)
        )

      _other ->
        workflow
    end
  end

  defp auto_review_child_workflow(
         workflow,
         _node,
         _mode,
         _workspace,
         _task,
         _decider,
         _opts,
         limit
       )
       when limit <= 0,
       do: workflow

  defp auto_review_child_workflow(workflow, node, mode, workspace, task, decider, opts, limit) do
    case StandardAgent.latest_review_request(workflow) do
      %ReviewRequest{} = request ->
        context = %{
          child_agent?: true,
          node_id: node.id,
          node_kind: node.kind,
          mode: mode,
          workspace_root: workspace.root,
          task: task
        }

        case decider.(request, context) do
          {:ok, %ReviewDecision{status: status} = decision} when status in [:approved, :edited] ->
            emit_node_stage(opts, :child_agent_review_decided, :ok, %{
              node_id: node.id,
              kind: node.kind,
              mode: mode,
              resume_key: request.resume_key,
              decision_status: decision.status
            })

            workflow
            |> Workflow.react_until_satisfied(%{agent_id: "coding", review_decision: decision})
            |> auto_review_child_workflow(node, mode, workspace, task, decider, opts, limit - 1)

          _other ->
            workflow
        end

      _other ->
        workflow
    end
  end

  defp child_progress_sink(opts, node, mode, workspace) do
    fn tick ->
      emit_node_stage(
        opts,
        :child_agent_progress,
        :running,
        Map.merge(tick, %{
          node_id: node.id,
          kind: node.kind,
          mode: mode,
          workspace_root: workspace.root
        })
      )
    end
  end

  defp child_runtime_timeout(node, agent_opts, context, opts) do
    requested_timeout_ms =
      param(node, :max_runtime_ms) ||
        param(node, :timeout_ms) ||
        Keyword.get(opts, :max_child_runtime_ms) ||
        Keyword.get(agent_opts, :child_max_runtime_ms) ||
        default_child_runtime_timeout(node, opts)

    reserve_ms = downstream_runtime_reserve_ms(node, context, opts)
    cap_child_timeout_to_remaining_budget(node, requested_timeout_ms, opts, reserve_ms)
  end

  defp default_child_runtime_timeout(node, opts) do
    mode = normalize_child_mode(param(node, :mode) || :read_only)
    target_ms = child_runtime_mode_cap(mode, opts)

    case Keyword.get(opts, :max_runtime_ms) do
      max_runtime_ms when is_integer(max_runtime_ms) and max_runtime_ms > 0 ->
        parent_cap_ms =
          max_runtime_ms
          |> div(2)
          |> max(@min_default_child_runtime_ms)

        target_ms
        |> min(parent_cap_ms)

      :infinity ->
        target_ms

      _other ->
        target_ms
    end
  end

  defp child_runtime_mode_cap(mode, opts) do
    caps = Keyword.get(opts, :child_runtime_mode_caps, %{})

    from_opts =
      case caps do
        caps when is_map(caps) ->
          Map.get(caps, mode) || Map.get(caps, Atom.to_string(mode))

        caps when is_list(caps) ->
          Keyword.get(caps, mode) || Keyword.get(caps, Atom.to_string(mode))

        _other ->
          nil
      end

    cond do
      is_integer(from_opts) and from_opts > 0 ->
        from_opts

      is_integer(Keyword.get(opts, :default_child_runtime_ms)) ->
        Keyword.get(opts, :default_child_runtime_ms)

      true ->
        Map.get(@default_child_runtime_by_mode, mode, @default_child_runtime_ms)
    end
  end

  defp normalize_child_mode(mode) when is_atom(mode), do: mode

  defp normalize_child_mode(mode) when is_binary(mode) do
    case String.replace(mode, "-", "_") do
      "read_only" -> :read_only
      "explain_repo" -> :explain_repo
      "review" -> :review
      "triage_bug" -> :triage_bug
      "verify" -> :verify
      "write_tests" -> :write_tests
      "fix_ci" -> :fix_ci
      "patch" -> :patch
      _other -> :read_only
    end
  end

  defp normalize_child_mode(_mode), do: :read_only

  defp downstream_runtime_reserve_ms(node, context, opts) do
    if Keyword.get(opts, :reserve_downstream_runtime?, true) do
      context.proposal.nodes
      |> Enum.reject(&(&1.id == node.id))
      |> Enum.reduce(0, fn candidate, acc ->
        acc + downstream_node_reserve_ms(candidate, opts)
      end)
      |> min(Keyword.get(opts, :max_downstream_runtime_reserve_ms, 45_000))
    else
      0
    end
  end

  defp downstream_node_reserve_ms(%{kind: :agent} = node, opts) do
    mode = normalize_child_mode(param(node, :mode) || :read_only)

    cond do
      repair_node?(node) ->
        Keyword.get(opts, :repair_runtime_reserve_ms, 20_000)

      mode in [:verify, :write_tests, :fix_ci] ->
        Keyword.get(opts, :verification_runtime_reserve_ms, 10_000)

      true ->
        Keyword.get(opts, :child_runtime_reserve_ms, 5_000)
    end
  end

  defp downstream_node_reserve_ms(%{kind: :verification_gate}, opts),
    do: Keyword.get(opts, :verification_runtime_reserve_ms, 10_000)

  defp downstream_node_reserve_ms(_node, _opts), do: 0

  defp repair_node?(node) do
    id = String.downcase(to_string(node.id))
    task = String.downcase(to_string(param(node, :task) || ""))
    mode = String.downcase(to_string(param(node, :mode) || ""))

    String.contains?(id, "repair") or String.contains?(task, "repair") or
      String.contains?(mode, "repair")
  end

  defp cap_child_timeout_to_remaining_budget(_node, nil, _opts, _reserve_ms), do: nil
  defp cap_child_timeout_to_remaining_budget(_node, :infinity, _opts, _reserve_ms), do: :infinity

  defp cap_child_timeout_to_remaining_budget(node, timeout_ms, opts, reserve_ms) do
    case Keyword.get(opts, :run_deadline_ms) do
      deadline_ms when is_integer(deadline_ms) ->
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)
        child_budget_ms = remaining_ms - @child_runtime_completion_reserve_ms - reserve_ms

        emit_node_stage(opts, :child_budget_selected, :running, %{
          node_id: node.id,
          kind: node.kind,
          current_child: node_child_id(node),
          child_agent_id: node_child_id(node),
          requested_timeout_ms: timeout_ms,
          remaining_ms: remaining_ms,
          downstream_reserve_ms: reserve_ms,
          completion_reserve_ms: @child_runtime_completion_reserve_ms,
          selected_timeout_ms:
            cond do
              child_budget_ms >= @min_default_child_runtime_ms ->
                min(timeout_ms, child_budget_ms)

              remaining_ms > 0 ->
                max(div(remaining_ms, 2), 1)

              true ->
                1
            end
        })

        cond do
          child_budget_ms >= @min_default_child_runtime_ms ->
            min(timeout_ms, child_budget_ms)

          remaining_ms > 0 ->
            max(div(remaining_ms, 2), 1)

          true ->
            1
        end

      _other ->
        timeout_ms
    end
  end

  defp failed_child_result(node, %Error{} = error) do
    ChildResult.new!(:failed,
      id: node.id,
      unresolved_risks: [error.message],
      summary: error.message,
      metadata: %{
        source: :standard_coding_agent,
        error_kind: error.kind,
        error_details: error.details
      }
    )
  end

  defp verification_contract(node, context) do
    objective = param(node, :objective) || context.proposal.objective

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

  defp put_new_key(map, key, value) do
    string_key = Atom.to_string(key)

    if Map.has_key?(map, key) or Map.has_key?(map, string_key) do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp agent_workspace(node, context) do
    workspace_path = param(node, :workspace_path) || param(node, :cwd) || param(node, :root)

    if is_binary(workspace_path) and workspace_path != "" and workspace_path != "." do
      case Workspace.resolve_path(context.workspace, workspace_path, :write) do
        {:ok, resolved} ->
          if File.dir?(resolved.path) do
            {:ok,
             Workspace.new!(
               root: resolved.path,
               persistence: context.workspace.persistence,
               metadata:
                 Map.merge(context.workspace.metadata, %{
                   parent_workspace_root: context.workspace.root,
                   scoped_from: resolved.relative
                 })
             )}
          else
            {:error,
             Error.validation("agent workspace_path does not exist",
               source: __MODULE__,
               details: %{workspace_path: workspace_path, resolved_path: resolved.path}
             )}
          end

        {:error, error} ->
          {:error, error}
      end
    else
      {:ok, context.workspace}
    end
  end

  defp scoped_agent_task(task, %Workspace{} = workspace, context) do
    """
    #{task}

    Workspace scope:
    - Your workspace root is #{workspace.root}.
    - The parent RLM objective is: #{context.proposal.objective}
    - Only edit files inside this workspace root.
    - Do not edit similarly named sibling projects or prior exercise artifacts.
    """
  end

  defp output_from_context(nil, _proposal), do: nil

  defp output_from_context(context, proposal) do
    Map.get(context.outputs, output_node_id(proposal)) || context.outputs
  end

  defp output_node_id(%WorkflowProposal{nodes: []}), do: nil

  defp output_node_id(%WorkflowProposal{nodes: nodes, edges: edges}) do
    sinks =
      edges
      |> Enum.map(& &1.from)
      |> MapSet.new()

    nodes
    |> topological_order(edges)
    |> Enum.reverse()
    |> Enum.find_value(fn node ->
      if MapSet.member?(sinks, node.id), do: nil, else: node.id
    end)
  end

  defp topological_order(nodes, edges) do
    node_by_id = Map.new(nodes, &{&1.id, &1})

    {incoming_counts, children_by_parent} =
      Enum.reduce(edges, initial_graph_indexes(nodes), fn edge, {incoming_counts, children} ->
        if Map.has_key?(node_by_id, edge.from) and Map.has_key?(node_by_id, edge.to) do
          {
            Map.update!(incoming_counts, edge.to, &(&1 + 1)),
            Map.update!(children, edge.from, &(&1 ++ [edge.to]))
          }
        else
          {incoming_counts, children}
        end
      end)

    roots =
      nodes
      |> Enum.map(& &1.id)
      |> Enum.filter(&(Map.fetch!(incoming_counts, &1) == 0))

    ordered_ids = drain_topological(roots, incoming_counts, children_by_parent, [])

    if length(ordered_ids) == length(nodes) do
      Enum.map(ordered_ids, &Map.fetch!(node_by_id, &1))
    else
      nodes
    end
  end

  defp initial_graph_indexes(nodes) do
    {
      Map.new(nodes, &{&1.id, 0}),
      Map.new(nodes, &{&1.id, []})
    }
  end

  defp drain_topological([], _incoming_counts, _children_by_parent, ordered),
    do: Enum.reverse(ordered)

  defp drain_topological([node_id | queue], incoming_counts, children_by_parent, ordered) do
    {incoming_counts, newly_ready} =
      children_by_parent
      |> Map.get(node_id, [])
      |> Enum.reduce({incoming_counts, []}, fn child_id, {counts, ready} ->
        count = max(Map.fetch!(counts, child_id) - 1, 0)
        counts = Map.put(counts, child_id, count)
        ready = if count == 0, do: ready ++ [child_id], else: ready
        {counts, ready}
      end)

    drain_topological(queue ++ newly_ready, incoming_counts, children_by_parent, [
      node_id | ordered
    ])
  end

  defp parent_ids(node_id, edges) do
    edges
    |> Enum.filter(&(&1.to == node_id))
    |> Enum.map(& &1.from)
  end

  defp safe_name(id) do
    id
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
    |> String.slice(0, 32)
  end

  defp param(node, key),
    do: Map.get(node.params, key) || Map.get(node.params, Atom.to_string(key))

  defp config_value(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp config_value(config, key, default) when is_list(config) do
    Keyword.get(config, key, Keyword.get(config, Atom.to_string(key), default))
  end

  defp config_value(_config, _key, default), do: default

  defp command_args(node) do
    args = normalize_map(param(node, :args) || %{})

    args
    |> put_new_present(:argv, param(node, :argv))
    |> put_new_present(:command, param(node, :command))
    |> put_new_present(:cwd, param(node, :cwd))
    |> put_new_present(:timeout_ms, param(node, :timeout_ms))
    |> put_new_present(:env, param(node, :env))
  end

  defp put_new_present(map, _key, nil), do: map
  defp put_new_present(map, key, value), do: Map.put_new(map, key, value)

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp maybe_put_client(llm_opts, nil), do: llm_opts
  defp maybe_put_client(llm_opts, client), do: Keyword.put_new(llm_opts, :client, client)

  defp emit_node_stage(opts, stage, status, data) do
    sink = Keyword.get(opts, :event_sink) || Keyword.get(opts, :stage_sink)

    if is_function(sink, 1) do
      event = %{
        id: Ids.unique("rlm-node-stage:#{stage}"),
        run_id: Keyword.get(opts, :run_id),
        stage: stage,
        status: status,
        at: DateTime.utc_now(),
        data: data
      }

      try do
        sink.(event)
      rescue
        _exception -> :ok
      end
    end

    :ok
  end

  defp emit_node_budget_context(opts, node) do
    case node_budget_context(opts, node) do
      nil -> :ok
      data -> emit_node_stage(opts, :node_budget_selected, :running, data)
    end
  end

  defp node_budget_context(opts, node) do
    max_runtime_ms = Keyword.get(opts, :max_runtime_ms)
    deadline_ms = Keyword.get(opts, :run_deadline_ms)

    cond do
      is_integer(deadline_ms) ->
        remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

        %{
          node_id: node.id,
          kind: node.kind,
          current_child: node_child_id(node),
          max_runtime_ms: max_runtime_ms,
          remaining_ms: remaining_ms,
          selected_timeout_ms: node_selected_timeout_ms(remaining_ms, max_runtime_ms)
        }

      is_integer(max_runtime_ms) and max_runtime_ms > 0 ->
        %{
          node_id: node.id,
          kind: node.kind,
          current_child: node_child_id(node),
          max_runtime_ms: max_runtime_ms,
          selected_timeout_ms: max_runtime_ms
        }

      true ->
        nil
    end
  end

  defp node_child_id(node), do: "#{node.id}:#{node.kind}"

  defp node_selected_timeout_ms(remaining_ms, max_runtime_ms)
       when is_integer(remaining_ms) and is_integer(max_runtime_ms) and max_runtime_ms > 0,
       do: min(remaining_ms, max_runtime_ms)

  defp node_selected_timeout_ms(remaining_ms, _max_runtime_ms) when is_integer(remaining_ms),
    do: remaining_ms

  defp node_selected_timeout_ms(_remaining_ms, max_runtime_ms), do: max_runtime_ms

  defp normalize_event_status(status) when status in [:satisfied, :completed, :ok], do: :ok
  defp normalize_event_status(status) when status in [:needs_review, :review], do: :review
  defp normalize_event_status(status) when status in [:partial, :blocked], do: :blocked
  defp normalize_event_status(status) when status in [:failed, :error], do: :error
  defp normalize_event_status(_status), do: :ok

  defp summarize_node_output(%ChildResult{} = result) do
    %{
      type: :child_result,
      status: result.status,
      summary: result.summary,
      changed_files: result.changed_files,
      checks_attempted: result.checks_attempted,
      commands: result.commands,
      unresolved_risks: result.unresolved_risks,
      review_request: map_value(result.metadata, :review_request)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp summarize_node_output(%{status: status} = output) do
    output
    |> Map.take([:status, :summary, :changed_files, :verification_evidence, :unresolved_risks])
    |> Map.put_new(:status, status)
  end

  defp summarize_node_output(output) when is_binary(output) do
    %{type: :text, preview: String.slice(output, 0, 1_000)}
  end

  defp summarize_node_output(output) do
    %{type: :value, preview: inspect(output, limit: 20, printable_limit: 1_000)}
  end

  defp error_summary(%Error{} = error) do
    %{
      kind: error.kind,
      message: error.message,
      details: error.details
    }
  end
end
