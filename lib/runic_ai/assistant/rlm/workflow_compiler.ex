defmodule RunicAI.Assistant.RLM.WorkflowCompiler do
  @moduledoc """
  Compiles accepted assistant workflow blueprints into executable Runic graphs.
  """

  alias Runic.Workflow
  alias Runic.Workflow.SchedulerPolicy
  alias RunicAI.Assistant.RLM.BlueprintGraph
  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentFactory
  alias RunicAI.RLM.ComponentSpec
  alias RunicAI.RLM.ComponentRuntime
  alias RunicAI.RLM.WorkflowExecutor
  alias RunicAI.RLM.WorkflowMetrics
  alias RunicAI.RLM.WorkflowResults

  @type compiled :: %{
          required(:workflow) => Workflow.t(),
          required(:blueprint) => WorkflowBlueprint.t(),
          required(:validation_report) => BlueprintValidator.report(),
          required(:node_names) => %{String.t() => String.t()},
          required(:output_name) => String.t(),
          required(:component_specs) => [map()],
          required(:graph_summary) => map(),
          required(:run_context_requirements) => map(),
          required(:scheduler_policies) => [term()]
        }

  @spec compile(WorkflowBlueprint.t() | map(), Workspace.t(), keyword()) ::
          {:ok, compiled()} | {:error, Error.t()}
  def compile(blueprint_input, %Workspace{} = workspace, opts \\ []) when is_list(opts) do
    with {:ok, blueprint} <- WorkflowBlueprint.from_input(blueprint_input),
         {:ok, report} <- BlueprintValidator.validate(blueprint, validation_opts(opts)),
         {:ok, blueprint_graph} <- BlueprintGraph.build(blueprint),
         {:ok, base_context} <- ComponentRuntime.initial_context(workspace, blueprint, opts) do
      ordered = Enum.map(blueprint_graph.ordered_specs, & &1.blueprint)

      node_names =
        blueprint_graph.ordered_specs
        |> Enum.with_index(1)
        |> Map.new(fn {spec, index} ->
          {spec.id, "assistant_node_#{index}_#{safe_name(spec.id)}"}
        end)

      input_name = "assistant_input"

      compile_opts = opts

      Workflow.new(name: "assistant_rlm:#{safe_name(blueprint.id)}")
      |> Workflow.add(ComponentFactory.input_step(name: input_name))
      |> build_workflow(blueprint_graph, node_names, input_name, compile_opts)
      |> case do
        {:ok, workflow} ->
          output_name =
            Map.fetch!(node_names, BlueprintGraph.output_component_id(blueprint_graph))

          workflow =
            workflow
            |> attach_scheduler_policies(blueprint_graph, node_names, blueprint)
            |> Workflow.put_run_context(
              runtime_context(base_context, blueprint_graph, node_names, opts)
            )

          with :ok <- validate_run_context(workflow) do
            {:ok,
             %{
               workflow: workflow,
               blueprint: blueprint,
               validation_report: report,
               ordered_components: ordered,
               node_names: node_names,
               output_name: output_name,
               component_specs: Enum.map(blueprint_graph.ordered_specs, &ComponentSpec.summary/1),
               graph_summary: graph_summary(blueprint_graph, workflow, node_names, opts),
               run_context_requirements: Workflow.required_context_keys(workflow),
               scheduler_policies: workflow.scheduler_policies
             }}
          end

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  @spec run(WorkflowBlueprint.t() | map(), Workspace.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(blueprint_input, %Workspace{} = workspace, input \\ %{}, opts \\ [])
      when is_map(input) and is_list(opts) do
    started_at_ms = System.monotonic_time(:millisecond)

    with {:ok, compiled} <- compile(blueprint_input, workspace, opts),
         {:ok, workflow} <-
           WorkflowExecutor.run(compiled.workflow, input, executor_opts(opts, compiled)) do
      elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms
      {:ok, result(compiled, workflow, elapsed_ms: elapsed_ms)}
    end
  end

  @spec result(compiled(), Workflow.t(), keyword()) :: map()
  def result(compiled, %Workflow{} = workflow, opts \\ []) do
    extracted = WorkflowResults.extract(workflow, compiled, opts)

    %{
      blueprint: compiled.blueprint,
      proposal: compiled.blueprint,
      validation_report: compiled.validation_report,
      compiled: Map.drop(compiled, [:workflow, :ordered_components]),
      workflow: workflow,
      output: extracted.output,
      artifacts: extracted.artifacts,
      scorecard: extracted.scorecard,
      budget_summary: extracted.budget_summary,
      execution_metrics: extracted.execution_metrics,
      native_nodes: extracted.native_nodes,
      facts: extracted.facts,
      intermediate_outputs: extracted.intermediate_outputs,
      component_results: extracted.component_results
    }
  end

  defp build_workflow(workflow, %BlueprintGraph{} = blueprint_graph, node_names, input_name, opts) do
    initial = %{workflow: workflow, native_maps: %{}}

    Enum.reduce_while(blueprint_graph.ordered_specs, {:ok, initial}, fn spec, {:ok, state} ->
      parents = BlueprintGraph.parent_ids(blueprint_graph, spec.id)

      to =
        if parents == [] do
          input_name
        else
          Enum.map(parents, &Map.fetch!(node_names, &1))
        end

      case add_spec_component(state, spec, parents, to, node_names, opts) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, %{workflow: workflow}} -> {:ok, workflow}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp add_spec_component(
         state,
         %ComponentSpec{execution_shape: :map} = spec,
         _parents,
         to,
         node_names,
         _opts
       ) do
    node_name = Map.fetch!(node_names, spec.id)
    items_name = native_map_items_name(node_name)

    with {:ok, workflow} <-
           workflow_add(
             state.workflow,
             ComponentFactory.map_items_step(spec, name: items_name),
             to,
             spec
           ),
         {:ok, map_component} <- ComponentFactory.native_map(spec, name: node_name),
         {:ok, workflow} <- workflow_add(workflow, map_component, items_name, spec) do
      {:ok,
       %{state | workflow: workflow, native_maps: Map.put(state.native_maps, spec.id, node_name)}}
    end
  end

  defp add_spec_component(
         state,
         %ComponentSpec{execution_shape: :reduce} = spec,
         parents,
         _to,
         node_names,
         _opts
       ) do
    node_name = Map.fetch!(node_names, spec.id)
    reduce_name = native_reduce_name(node_name)

    case native_map_parent(parents, state.native_maps) do
      {:ok, map_name} ->
        map_component = Workflow.get_component(state.workflow, map_name)

        with {:ok, reduce_component} <-
               ComponentFactory.native_reduce(spec, map_name, name: reduce_name),
             {:ok, workflow} <-
               workflow_add(state.workflow, reduce_component, map_component, spec),
             {:ok, workflow} <-
               workflow_add(
                 workflow,
                 ComponentFactory.reduce_finalize_step(spec, name: node_name),
                 reduce_component.fan_in,
                 spec
               ) do
          {:ok, %{state | workflow: workflow}}
        end

      :error ->
        {:error,
         Error.validation("reduce-shaped assistant component requires a native map parent",
           source: __MODULE__,
           details: %{code: :missing_native_map_parent, component_id: spec.id, type: spec.type}
         )}
    end
  end

  defp add_spec_component(state, %ComponentSpec{} = spec, _parents, to, node_names, opts) do
    with {:ok, runic_component} <-
           ComponentFactory.to_runic(spec,
             name: Map.fetch!(node_names, spec.id),
             native_shapes?: Keyword.get(opts, :native_shapes?, true)
           ) do
      with {:ok, workflow} <- workflow_add(state.workflow, runic_component, to, spec) do
        {:ok, %{state | workflow: workflow}}
      end
    end
  end

  defp native_map_parent(parents, native_maps) do
    parents
    |> Enum.find_value(fn parent ->
      case Map.fetch(native_maps, parent) do
        {:ok, name} -> {:ok, name}
        :error -> nil
      end
    end)
    |> case do
      {:ok, name} -> {:ok, name}
      nil -> :error
    end
  end

  defp workflow_add(workflow, runic_component, to, %ComponentSpec{} = spec) do
    {:ok, Workflow.add(workflow, runic_component, to: to)}
  rescue
    exception in [Runic.IncompatiblePortError] ->
      {:error,
       Error.validation("assistant workflow component port contracts are incompatible",
         source: __MODULE__,
         details: %{
           code: :port_type_mismatch,
           component_id: spec.id,
           type: spec.type,
           to: List.wrap(to),
           reasons: exception.reasons,
           message: Exception.message(exception),
           producer: component_name(exception.producer),
           consumer: component_name(exception.consumer)
         }
       )}
  end

  defp validation_opts(opts) do
    [
      max_generated_function_tier: Keyword.get(opts, :max_generated_function_tier, :tier1),
      max_nodes: Keyword.get(opts, :max_nodes)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp runtime_context(base_context, %BlueprintGraph{} = blueprint_graph, node_names, opts) do
    global = %{
      base_context: base_context,
      workspace: base_context.workspace,
      objective: base_context.objective,
      sources: base_context.sources,
      policies: base_context.policies,
      budgets: base_context.budgets,
      metadata: base_context.metadata,
      event_sink: base_context.event_sink,
      opts: opts,
      components_by_id: Map.new(blueprint_graph.ordered_specs, &{&1.id, &1.blueprint}),
      component_policies_by_id: component_policies_by_id(blueprint_graph)
    }

    component_context =
      blueprint_graph.ordered_specs
      |> Enum.flat_map(fn spec ->
        name = Map.fetch!(node_names, spec.id)
        context = component_context(spec, opts)

        [{name, context} | internal_component_contexts(spec, name, context)]
      end)
      |> Map.new()

    Map.put(component_context, :_global, global)
  end

  defp component_context(%ComponentSpec{} = spec, opts) do
    %{
      component: spec.blueprint,
      component_id: spec.id,
      component_type: spec.type,
      params: spec.params,
      spec: spec,
      opts: opts
    }
  end

  defp internal_component_contexts(%ComponentSpec{execution_shape: :map}, name, context) do
    [{native_map_items_name(name), context}]
  end

  defp internal_component_contexts(_spec, _name, _context), do: []

  defp validate_run_context(%Workflow{} = workflow) do
    context = Workflow.get_run_context(workflow)

    case Workflow.validate_run_context(workflow, context) do
      :ok ->
        :ok

      {:error, missing} ->
        {:error,
         Error.validation("assistant workflow runtime context is incomplete",
           source: __MODULE__,
           details: %{code: :missing_runtime_context, missing: missing}
         )}
    end
  end

  defp attach_scheduler_policies(
         %Workflow{} = workflow,
         %BlueprintGraph{} = blueprint_graph,
         node_names,
         %WorkflowBlueprint{} = blueprint
       ) do
    workflow
    |> attach_budget_policy(blueprint)
    |> then(fn workflow ->
      Enum.reduce(blueprint_graph.ordered_specs, workflow, fn spec, workflow ->
        case scheduler_policy(spec) do
          nil ->
            workflow

          policy ->
            Workflow.add_scheduler_policy(
              workflow,
              name_matcher(Map.fetch!(node_names, spec.id)),
              policy
            )
        end
      end)
    end)
  end

  defp attach_budget_policy(%Workflow{} = workflow, %WorkflowBlueprint{} = blueprint) do
    case positive_integer(
           get_in(blueprint.policies, [:budgets, :max_runtime_ms]) ||
             get_in(blueprint.policies, ["budgets", "max_runtime_ms"])
         ) do
      nil ->
        workflow

      max_runtime_ms ->
        Workflow.append_scheduler_policy(workflow, :default, %{timeout_ms: max_runtime_ms})
    end
  end

  defp scheduler_policy(%ComponentSpec{} = spec) do
    spec.type
    |> preset_policy()
    |> Map.merge(native_execution_policy(spec))
    |> Map.merge(policy_overrides(spec.policy))
    |> reject_empty_policy()
  end

  defp name_matcher(name), do: {:name, Regex.compile!("^#{Regex.escape(to_string(name))}$")}

  defp preset_policy(type) when type in [:llm_map, :record_map, :llm_leaf] do
    SchedulerPolicy.llm_policy() |> policy_map()
  end

  defp preset_policy(type)
       when type in [
              :source_discovery,
              :source_splitter,
              :source_materializer,
              :tabular_parser,
              :document_compare,
              :artifact_writer
            ] do
    SchedulerPolicy.io_policy() |> policy_map() |> Map.put(:on_failure, :halt)
  end

  defp preset_policy(_type), do: %{}

  defp policy_overrides(policy) when is_map(policy) do
    scheduler = get(policy, :scheduler, nil)

    scheduler
    |> scheduler_preset()
    |> Map.merge(policy_value(policy, :max_retries, ["max_retries", "retries"]))
    |> Map.merge(policy_value(policy, :timeout_ms, ["timeout_ms", "timeout"]))
    |> Map.merge(policy_value(policy, :base_delay_ms, ["base_delay_ms"]))
    |> Map.merge(policy_value(policy, :max_delay_ms, ["max_delay_ms"]))
    |> Map.merge(
      enum_policy_value(policy, :backoff, ["backoff"], [:none, :linear, :exponential, :jitter])
    )
    |> Map.merge(enum_policy_value(policy, :on_failure, ["on_failure"], [:halt, :skip]))
    |> Map.merge(
      enum_policy_value(policy, :execution_mode, ["execution_mode"], [:sync, :async, :durable])
    )
    |> Map.merge(
      enum_policy_value(policy, :priority, ["priority"], [:low, :normal, :high, :critical])
    )
  end

  defp policy_overrides(_policy), do: %{}

  defp native_execution_policy(%ComponentSpec{type: type} = spec)
       when type in [:llm_map, :record_map] do
    spec.params
    |> get(:max_concurrency, nil)
    |> positive_integer()
    |> case do
      nil -> %{}
      max_concurrency -> %{executor_opts: [max_concurrency: max_concurrency]}
    end
  end

  defp native_execution_policy(_spec), do: %{}

  defp component_policies_by_id(%BlueprintGraph{} = blueprint_graph) do
    blueprint_graph.ordered_specs
    |> Enum.map(fn spec -> {spec.id, scheduler_policy(spec)} end)
    |> Enum.reject(fn {_id, policy} -> is_nil(policy) end)
    |> Map.new()
  end

  defp scheduler_preset(:llm), do: SchedulerPolicy.llm_policy() |> policy_map()
  defp scheduler_preset("llm"), do: SchedulerPolicy.llm_policy() |> policy_map()
  defp scheduler_preset(:io), do: SchedulerPolicy.io_policy() |> policy_map()
  defp scheduler_preset("io"), do: SchedulerPolicy.io_policy() |> policy_map()
  defp scheduler_preset(:fast_fail), do: SchedulerPolicy.fast_fail() |> policy_map()
  defp scheduler_preset("fast_fail"), do: SchedulerPolicy.fast_fail() |> policy_map()
  defp scheduler_preset("fast-fail"), do: SchedulerPolicy.fast_fail() |> policy_map()
  defp scheduler_preset(_scheduler), do: %{}

  defp policy_map(%SchedulerPolicy{} = policy) do
    policy
    |> Map.from_struct()
    |> Map.take([:max_retries, :backoff, :base_delay_ms, :max_delay_ms, :timeout_ms, :on_failure])
  end

  defp policy_value(policy, key, aliases) do
    value =
      [key | aliases]
      |> Enum.find_value(fn key -> get(policy, key, nil) end)

    case positive_integer(value) do
      nil -> %{}
      integer -> %{key => integer}
    end
  end

  defp enum_policy_value(policy, key, aliases, allowed) do
    value =
      [key | aliases]
      |> Enum.find_value(fn key -> get(policy, key, nil) end)
      |> normalize_policy_atom()

    if value in allowed, do: %{key => value}, else: %{}
  end

  defp normalize_policy_atom(value) when is_atom(value), do: value

  defp normalize_policy_atom(value) when is_binary(value) do
    case value do
      "none" -> :none
      "linear" -> :linear
      "exponential" -> :exponential
      "jitter" -> :jitter
      "halt" -> :halt
      "skip" -> :skip
      "sync" -> :sync
      "async" -> :async
      "durable" -> :durable
      "low" -> :low
      "normal" -> :normal
      "high" -> :high
      "critical" -> :critical
      _other -> nil
    end
  end

  defp normalize_policy_atom(_value), do: nil

  defp reject_empty_policy(policy) when map_size(policy) == 0, do: nil
  defp reject_empty_policy(policy), do: policy

  defp graph_summary(
         %BlueprintGraph{} = blueprint_graph,
         %Workflow{} = workflow,
         node_names,
         opts
       ) do
    blueprint_graph
    |> BlueprintGraph.summary(node_names: node_names)
    |> Map.put(:runic, %{
      edgelist: Enum.map(Workflow.to_edgelist(workflow), &edgelist_entry/1),
      build_log_count: length(Workflow.build_log(workflow)),
      required_context_keys: json_context_requirements(Workflow.required_context_keys(workflow)),
      scheduler_policy_count: length(workflow.scheduler_policies),
      native_nodes:
        workflow
        |> WorkflowMetrics.runtime_nodes(%{
          component_specs: Enum.map(blueprint_graph.ordered_specs, &ComponentSpec.summary/1),
          node_names: node_names
        })
        |> Enum.map(&Map.drop(&1, [:last_output])),
      serializers: graph_serializers(workflow, opts)
    })
  end

  defp graph_serializers(%Workflow{} = workflow, opts) do
    if Keyword.get(opts, :include_graph_serializers?, true) do
      %{
        mermaid: Runic.Workflow.Serializers.Mermaid.serialize(workflow),
        dot: Runic.Workflow.Serializers.DOT.serialize(workflow),
        cytoscape: Runic.Workflow.Serializers.Cytoscape.serialize(workflow)
      }
    else
      %{}
    end
  end

  defp edgelist_entry({from, to}) do
    %{from: inspect(from), to: inspect(to)}
  end

  defp edgelist_entry({from, to, label}) do
    %{from: inspect(from), to: inspect(to), label: inspect(label)}
  end

  defp edgelist_entry(entry), do: inspect(entry)

  defp json_context_requirements(requirements) do
    Map.new(requirements, fn {component, keys} ->
      {to_string(component),
       Enum.map(keys, fn
         {key, :required} -> %{key: key, required?: true}
         {key, {:optional, default}} -> %{key: key, required?: false, default: inspect(default)}
       end)}
    end)
  end

  defp executor_opts(opts, compiled) do
    opts
    |> Keyword.take([
      :async,
      :max_concurrency,
      :timeout,
      :scheduler_policies,
      :scheduler_policies_mode,
      :execution_mode,
      :runner_name,
      :workflow_id,
      :persist_runner?
    ])
    |> Keyword.put_new(:timeout, :infinity)
    |> maybe_put_deadline(compiled)
  end

  defp maybe_put_deadline(opts, compiled) do
    max_runtime_ms =
      get_in(compiled.blueprint.policies, [:budgets, :max_runtime_ms]) ||
        get_in(compiled.blueprint.policies, ["budgets", "max_runtime_ms"])

    case positive_integer(max_runtime_ms) do
      nil -> opts
      ms -> Keyword.put_new(opts, :deadline_at, System.monotonic_time(:millisecond) + ms)
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp component_name(%{name: name}) when not is_nil(name), do: name
  defp component_name(%{hash: hash}) when not is_nil(hash), do: hash
  defp component_name(component), do: inspect(component)

  defp native_map_items_name(name), do: "#{name}_items"
  defp native_reduce_name(name), do: "#{name}_fan_in"

  defp safe_name(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "workflow"
      value -> value
    end
  end

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)

  defp get(_map, _key, default), do: default
end
