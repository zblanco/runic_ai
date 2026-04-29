defmodule RunicAI.Coding.RLM.WorkflowCompiler do
  @moduledoc """
  Compile accepted RLM coding workflow proposals into executable Runic workflows.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Coding.Agent, as: StandardAgent
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.RLM.Checkpoint
  alias RunicAI.Coding.RLM.ChildContract
  alias RunicAI.Coding.RLM.ChildResult
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.EditPatchSet
  alias RunicAI.Coding.RLM.PlanPatchValidator
  alias RunicAI.Coding.RLM.Reducers
  alias RunicAI.Coding.RLM.RuntimeBudget
  alias RunicAI.Coding.RLM.VerificationGate
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.Coding.RLM.WorkflowValidator
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.RLM.Episode
  alias RunicAI.RLM.PlanPatch
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry

  @default_model "openai:gpt-5.4-mini"

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
         report = WorkflowValidator.validate(proposal, Keyword.get(opts, :validation_opts, [])),
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

    with %Definition{} = definition <- Registry.fetch!(registry, name),
         {:ok, output} <- Definition.execute(definition, args) do
      ok_episode(node, output)
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
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
        case run_standard_agent_child(mode, workspace, task, agent_opts, node, opts) do
          {:ok, summary} ->
            ChildResult.from_agent_summary(summary, child_contract, id: node.id)

          {:error, %Error{} = error} ->
            failed_child_result(node, error)
        end

      episode(node, child_result, ChildResult.episode_status(child_result))
    end
  end

  defp dispatch_node(%{kind: :edit} = node, context, _opts) do
    patch_set =
      param(node, :patch_set) ||
        %{
          objective: param(node, :objective) || context.proposal.objective,
          operations: List.wrap(param(node, :operations)),
          expected_changed_files: List.wrap(param(node, :expected_changed_files)),
          target_paths: List.wrap(param(node, :target_paths)),
          metadata: param(node, :metadata) || %{}
        }

    with {:ok, output} <- EditPatchSet.apply(context.workspace, patch_set) do
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
        CommandPolicy.new!(allowed_commands: ["mix", "git"], allow_shell: false)
      end)

    Tools.run_command(context.workspace, command_args(node), policy)
    |> case do
      {:ok, output} -> ok_episode(node, output)
      {:error, error} -> {:error, error}
    end
  end

  defp dispatch_node(%{kind: :script} = node, context, opts) do
    if Keyword.get(opts, :allow_scripts?, false) do
      policy =
        Keyword.get_lazy(opts, :script_command_policy, fn ->
          CommandPolicy.new!(
            allowed_commands: ["just_bash"],
            allow_shell: false,
            allow_just_bash: true,
            max_output_bytes: 16_384
          )
        end)

      Tools.run_command(
        context.workspace,
        %{
          backend: :just_bash,
          command: "just_bash",
          shell: param(node, :script) || "",
          timeout_ms: param(node, :timeout_ms) || 10_000
        },
        policy
      )
      |> case do
        {:ok, output} -> ok_episode(node, output)
        {:error, error} -> {:error, error}
      end
    else
      ok_episode(node, %{status: :blocked, reason: :script_execution_requires_opt_in})
    end
  end

  defp ok_episode(node, output), do: episode(node, output, :satisfied)

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
    update_in(
      context,
      [:child_results],
      &append_unique(&1, child_result, fn result -> result.id end)
    )
  end

  defp record_special_output(context, %{kind: :edit}, %{changed_paths: changed_paths} = output) do
    context
    |> update_in([:changed_files], &Enum.uniq(List.wrap(&1) ++ changed_paths))
    |> update_in(
      [:artifacts],
      &append_unique(&1, output, fn artifact -> inspect(artifact.id || artifact) end)
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

  defp record_special_output(context, %{kind: :command}, output) do
    update_in(context, [:command_results], &Enum.uniq(List.wrap(&1) ++ [output]))
  end

  defp record_special_output(context, _node, output) do
    update_in(context, [:artifacts], &Enum.uniq(List.wrap(&1) ++ List.wrap(output)))
  end

  defp append_unique(values, value, fun) do
    (List.wrap(values) ++ [value])
    |> Enum.uniq_by(fun)
  end

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
    Tools.default_registry(context.workspace,
      command_policy:
        Keyword.get_lazy(opts, :command_policy, fn ->
          CommandPolicy.new!(allowed_commands: ["git", "mix"], allow_shell: false)
        end)
    )
  end

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

  defp call_standard_agent(mode, workspace, task, opts) when mode in ["read_only", :read_only],
    do: StandardAgent.read_only(workspace, task, opts)

  defp call_standard_agent(mode, workspace, task, opts) when mode in ["patch", :patch],
    do: StandardAgent.patch(workspace, task, opts)

  defp call_standard_agent(mode, workspace, task, opts) when mode in ["verify", :verify],
    do: StandardAgent.verify(workspace, task, opts)

  defp call_standard_agent(_mode, workspace, task, opts),
    do: StandardAgent.read_only(workspace, task, opts)

  defp run_standard_agent_child(mode, workspace, task, agent_opts, node, opts) do
    RuntimeBudget.run(
      fn ->
        workflow = call_standard_agent(mode, workspace, task, agent_opts)
        {:ok, StandardAgent.summary(workflow)}
      end,
      timeout_ms: child_runtime_timeout(node, agent_opts, opts),
      stage: :workflow_child_agent,
      objective: task
    )
  end

  defp child_runtime_timeout(node, agent_opts, opts) do
    param(node, :max_runtime_ms) ||
      param(node, :timeout_ms) ||
      Keyword.get(agent_opts, :max_runtime_ms) ||
      Keyword.get(opts, :max_child_runtime_ms)
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
end
