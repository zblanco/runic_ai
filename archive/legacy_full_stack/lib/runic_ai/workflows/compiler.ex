defmodule RunicAI.Workflows.Compiler do
  @moduledoc """
  Staged lowering from workflow IR V1 into the existing native Runic compiler.

  V1 lowers the general component dialect through the assistant component
  compiler. A homogeneous coding dialect lowers through an explicit typed
  domain adapter into the existing coding compiler. Mixed-dialect graphs stay
  rejected until cross-dialect ports have real runtime semantics.
  """

  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Assistant.RLM.WorkflowCompiler, as: AssistantCompiler
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.WorkflowCompiler, as: CodingCompiler
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentCatalog
  alias RunicAI.RLM.WorkflowResults
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.Validator

  @type compiled :: %{
          required(:ir) => IR.t(),
          required(:semantic_hash) => String.t(),
          required(:compiled_hash) => String.t(),
          required(:validation_report) => Validator.report(),
          required(:source_map) => map(),
          required(:blueprint) => WorkflowBlueprint.t(),
          required(:runic) => map()
        }

  @spec compile(IR.t() | map(), Workspace.t(), keyword()) ::
          {:ok, compiled()} | {:error, Error.t()}
  def compile(input, %Workspace{} = workspace, opts \\ []) when is_list(opts) do
    with {:ok, ir} <- IR.from_input(input),
         {:ok, validation_report} <- Validator.validate(ir, mode: :runnable) do
      compile_dialect(ir, workspace, validation_report, opts)
    end
  end

  @spec run(IR.t() | map(), Workspace.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(input, %Workspace{} = workspace, runtime_input \\ %{}, opts \\ [])
      when is_map(runtime_input) and is_list(opts) do
    with {:ok, compiled} <- compile(input, workspace, opts),
         {:ok, result} <- run_compiled(compiled, workspace, runtime_input, opts) do
      {:ok, attach_compilation_evidence(result, compiled)}
    end
  end

  @doc false
  @spec execution_descriptor(compiled()) :: map()
  def execution_descriptor(%{dialect: :component, runic: runic} = compiled) do
    %{
      dialect: :component,
      semantic_hash: compiled.semantic_hash,
      compiled_hash: compiled.compiled_hash,
      runtime:
        Map.take(runic, [
          :blueprint,
          :component_specs,
          :node_names,
          :output_name,
          :validation_report
        ])
    }
  end

  def execution_descriptor(%{dialect: :coding, runic: runic} = compiled) do
    %{
      dialect: :coding,
      semantic_hash: compiled.semantic_hash,
      compiled_hash: compiled.compiled_hash,
      runtime: Map.take(runic, [:proposal, :node_names, :validation_report])
    }
  end

  @doc false
  @spec execution_result(map(), Runic.Workflow.t()) :: map()
  def execution_result(%{dialect: :component} = descriptor, %Runic.Workflow{} = workflow) do
    workflow
    |> WorkflowResults.extract(descriptor.runtime)
    |> Map.take([
      :output,
      :artifacts,
      :scorecard,
      :budget_summary,
      :execution_metrics,
      :native_nodes,
      :intermediate_outputs
    ])
    |> attach_execution_identity(descriptor)
  end

  def execution_result(%{dialect: :coding} = descriptor, %Runic.Workflow{} = workflow) do
    descriptor.runtime
    |> CodingCompiler.result(workflow)
    |> Map.take([:context, :output, :trace, :episodes])
    |> attach_execution_identity(descriptor)
  end

  @spec to_assistant_blueprint(IR.t()) :: {:ok, WorkflowBlueprint.t()} | {:error, Error.t()}
  def to_assistant_blueprint(%IR{} = ir) do
    with {:ok, components} <- components(ir) do
      WorkflowBlueprint.new(ir.objective, components,
        id: ir.id,
        sources: sources(ir),
        edges: blueprint_edges(ir),
        stop_conditions: stop_conditions(ir),
        policies: ir.policies,
        metadata: %{
          workflow_ir_format: ir.format,
          workflow_ir_version: ir.format_version,
          workflow_ir_revision: ir.revision,
          workflow_ir_hash: IR.semantic_hash(ir),
          source_metadata: ir.metadata
        }
      )
    end
  end

  defp compile_dialect(ir, workspace, validation_report, opts) do
    case dialects(ir) do
      [:component] -> compile_component(ir, workspace, validation_report, opts)
      [:coding] -> compile_coding(ir, workspace, validation_report, opts)
      dialects -> unsupported_dialects(ir, dialects)
    end
  end

  defp compile_component(ir, workspace, validation_report, opts) do
    with {:ok, blueprint} <- to_assistant_blueprint(ir),
         {:ok, runic} <- AssistantCompiler.compile(blueprint, workspace, opts) do
      compilation(ir, validation_report, :component, runic, %{blueprint: blueprint})
    end
  end

  defp compile_coding(ir, workspace, validation_report, opts) do
    with {:ok, proposal} <- to_coding_proposal(ir),
         {:ok, environment} <- CodebaseEnvironment.new(workspace, index?: true),
         {:ok, runic} <- CodingCompiler.compile(proposal, environment, opts) do
      compilation(ir, validation_report, :coding, runic, %{
        proposal: proposal,
        environment: environment,
        domain_validation_report: runic.validation_report
      })
    end
  end

  defp compilation(ir, validation_report, dialect, runic, extra) do
    semantic_hash = IR.semantic_hash(ir)
    source_map = semantic_source_map(runic.node_names)

    {:ok,
     Map.merge(
       %{
         ir: ir,
         dialect: dialect,
         semantic_hash: semantic_hash,
         compiled_hash: compiled_hash(semantic_hash, dialect, runic, source_map),
         validation_report: validation_report,
         source_map: source_map,
         runic: runic
       },
       extra
     )}
  end

  defp run_compiled(%{dialect: :component} = compiled, workspace, runtime_input, opts) do
    AssistantCompiler.run(compiled.blueprint, workspace, runtime_input, opts)
  end

  defp run_compiled(%{dialect: :coding} = compiled, _workspace, runtime_input, opts) do
    CodingCompiler.run(compiled.proposal, compiled.environment, runtime_input, opts)
  end

  defp attach_compilation_evidence(result, compiled) do
    result
    |> Map.put(:ir, compiled.ir)
    |> Map.put(:dialect, compiled.dialect)
    |> Map.put(:semantic_hash, compiled.semantic_hash)
    |> Map.put(:compiled_hash, compiled.compiled_hash)
    |> Map.put(:source_map, compiled.source_map)
  end

  defp attach_execution_identity(result, descriptor) do
    result
    |> Map.put(:dialect, descriptor.dialect)
    |> Map.put(:semantic_hash, descriptor.semantic_hash)
    |> Map.put(:compiled_hash, descriptor.compiled_hash)
  end

  @spec to_coding_proposal(IR.t()) :: {:ok, WorkflowProposal.t()} | {:error, Error.t()}
  def to_coding_proposal(%IR{} = ir) do
    nodes =
      ir.nodes
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn node ->
        %{
          id: node.id,
          kind: coding_kind(node),
          inputs: List.wrap(map_value(node.metadata, :legacy_inputs, [])),
          outputs: List.wrap(map_value(node.metadata, :legacy_outputs, [])),
          params: node.arguments,
          policy: node.policy,
          provenance: List.wrap(map_value(node.metadata, :provenance, [])),
          metadata: map_value(node.metadata, :source_metadata, %{})
        }
      end)

    edges =
      ir.edges
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&%{from: &1.from.node, to: &1.to.node})

    WorkflowProposal.new(ir.objective, nodes,
      id: ir.id,
      assumptions: List.wrap(map_value(ir.metadata, :assumptions, [])),
      sources: List.wrap(map_value(ir.metadata, :sources, [])),
      edges: edges,
      policies: ir.policies,
      expected_artifacts: coding_acceptance(ir.acceptance, :expected_artifact, :artifact),
      stop_conditions: coding_acceptance(ir.acceptance, :declared_stop_condition, :condition),
      metadata: map_value(ir.metadata, :source_metadata, %{})
    )
  end

  defp coding_acceptance(acceptance, kind, value_key) do
    acceptance
    |> Enum.filter(&(normalized_atom(map_value(&1, :kind)) == kind))
    |> Enum.map(&map_value(&1, value_key))
    |> Enum.reject(&is_nil/1)
  end

  defp coding_kind(node) do
    map_value(node.metadata, :source_kind) ||
      node.component |> String.replace_prefix("runic_ai/coding/", "") |> normalized_atom()
  end

  defp dialects(ir) do
    ir.nodes
    |> Map.values()
    |> Enum.map(&(contract_value(&1.contract, :dialect) |> normalized_atom()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unsupported_dialects(ir, dialects) do
    {:error,
     Error.validation("workflow IR contains nodes without a shared lowering",
       source: __MODULE__,
       details: %{
         code: :unsupported_workflow_dialect,
         dialects: dialects,
         nodes:
           ir.nodes
           |> Map.values()
           |> Enum.map(fn node ->
             %{
               id: node.id,
               component: node.component,
               dialect: contract_value(node.contract, :dialect)
             }
           end)
       }
     )}
  end

  defp components(%IR{} = ir) do
    ir.nodes
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      with {:ok, type} <- component_type(node.component),
           {:ok, component} <-
             ComponentBlueprint.new(node.id, type,
               params: node.arguments,
               policy: node.policy,
               provenance: List.wrap(map_value(node.metadata, :provenance)),
               metadata: %{
                 workflow_ir_node_id: node.id,
                 workflow_ir_contract_ref: contract_value(node.contract, :ref),
                 workflow_ir_contract_hash: contract_value(node.contract, :hash),
                 workflow_ir_effects: node.effects,
                 workflow_ir_replay: contract_value(node.contract, :replay, %{}),
                 source_metadata: map_value(node.metadata, :source_metadata, %{})
               }
             ) do
        {:cont, {:ok, [component | acc]}}
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, components} -> {:ok, Enum.reverse(components)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp component_type("runic_ai/" <> type_name) do
    case Enum.find(ComponentCatalog.types(), &(Atom.to_string(&1) == type_name)) do
      nil ->
        {:error,
         Error.validation("workflow IR component is not in the general component catalog",
           source: __MODULE__,
           details: %{code: :unknown_lowering_component, component: type_name}
         )}

      type ->
        {:ok, type}
    end
  end

  defp component_type(component) do
    {:error,
     Error.validation("workflow IR component key is not lowerable",
       source: __MODULE__,
       details: %{code: :unknown_lowering_component, component: component}
     )}
  end

  defp sources(%IR{} = ir) do
    ir.inputs
    |> Enum.filter(fn {_id, input} -> map_value(input, :kind) in [:source, "source"] end)
    |> Enum.map(fn {id, input} ->
      %{
        id: to_string(id),
        path: map_value(input, :path),
        metadata: map_value(input, :metadata, %{})
      }
    end)
  end

  defp blueprint_edges(%IR{} = ir) do
    ir.edges
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn edge -> %{from: edge.from.node, to: edge.to.node} end)
  end

  defp stop_conditions(%IR{} = ir) do
    Enum.map(ir.acceptance, fn acceptance ->
      map_value(acceptance, :condition) ||
        map_value(acceptance, :description) ||
        map_value(acceptance, :id)
    end)
  end

  defp semantic_source_map(node_names) do
    Map.new(node_names, fn {semantic_id, runic_name} ->
      {semantic_id, %{runic_nodes: [runic_name]}}
    end)
  end

  @doc false
  @spec compiled_hash(String.t(), atom(), map(), map()) :: String.t()
  def compiled_hash(semantic_hash, dialect, runic, source_map) do
    payload = %{
      semantic_hash: semantic_hash,
      dialect: dialect,
      source_map: source_map,
      graph_summary: stable_graph_summary(Map.get(runic, :graph_summary)),
      component_specs: Map.get(runic, :component_specs),
      node_names: Map.get(runic, :node_names)
    }

    payload
    |> canonical_hash_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Runic presentation serializers and edge lists contain VM-local component
  # hashes. They are useful diagnostics, but cannot identify a compiled
  # lowering across application restarts. Keep only the semantic and stable
  # native execution description in the durable fingerprint.
  defp stable_graph_summary(nil), do: nil

  defp stable_graph_summary(summary) when is_map(summary) do
    stable =
      Map.take(summary, [
        :id,
        :nodes,
        :roots,
        :edges,
        :objective,
        :stop_conditions,
        :batches,
        :leaves
      ])

    stable_runic =
      summary
      |> Map.get(:runic, %{})
      |> Map.take([
        :native_nodes,
        :required_context_keys,
        :build_log_count,
        :scheduler_policy_count
      ])

    Map.put(stable, :runic, stable_runic)
  end

  # Compilation starts from both freshly-authored structs and JSON-restored
  # immutable revisions. Those representations legitimately differ in atom
  # versus string keys and values while carrying identical workflow meaning.
  # Normalize the durable fingerprint so a saved workflow can be recompiled
  # and verified before execution.
  defp canonical_hash_term(%_{} = struct),
    do: struct |> Map.from_struct() |> canonical_hash_term()

  defp canonical_hash_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_hash_term(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_hash_term(list) when is_list(list), do: Enum.map(list, &canonical_hash_term/1)

  defp canonical_hash_term(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp canonical_hash_term(value), do: value

  defp contract_value(contract, key, default \\ nil),
    do: Map.get(contract, key, Map.get(contract, Atom.to_string(key), default))

  defp map_value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp normalized_atom(value) when is_atom(value), do: value

  defp normalized_atom(value) when is_binary(value) do
    case value do
      "component" -> :component
      "coding" -> :coding
      "llm_leaf" -> :llm_leaf
      "tool" -> :tool
      "command" -> :command
      "script" -> :script
      "computing" -> :computing
      "deterministic_step" -> :deterministic_step
      "agent" -> :agent
      "edit" -> :edit
      "verification_gate" -> :verification_gate
      "reducer" -> :reducer
      "review_gate" -> :review_gate
      "workflow_patch" -> :workflow_patch
      "declared_stop_condition" -> :declared_stop_condition
      "expected_artifact" -> :expected_artifact
      _other -> value
    end
  end

  defp normalized_atom(value), do: value
end
