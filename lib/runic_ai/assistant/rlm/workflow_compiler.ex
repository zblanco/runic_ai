defmodule RunicAI.Assistant.RLM.WorkflowCompiler do
  @moduledoc """
  Compiles accepted assistant workflow blueprints into executable Runic graphs.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.ExecutionContext
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.Components.ArtifactWriter
  alias RunicAI.RLM.Components.BlueprintTransform
  alias RunicAI.RLM.Components.BudgetLedger
  alias RunicAI.RLM.Components.DocumentCompare
  alias RunicAI.RLM.Components.HierarchicalReduce
  alias RunicAI.RLM.Components.LLMMap
  alias RunicAI.RLM.Components.ObjectiveScorecard
  alias RunicAI.RLM.Components.RecordGroup
  alias RunicAI.RLM.Components.RecordMap
  alias RunicAI.RLM.Components.ReportComposer
  alias RunicAI.RLM.Components.SourceDiscovery
  alias RunicAI.RLM.Components.SourceMaterializer
  alias RunicAI.RLM.Components.SourceSplitter
  alias RunicAI.RLM.Components.TabularParser

  @default_model "openai:gpt-5.4-mini"

  @type compiled :: %{
          required(:workflow) => Workflow.t(),
          required(:blueprint) => WorkflowBlueprint.t(),
          required(:validation_report) => BlueprintValidator.report(),
          required(:node_names) => %{String.t() => String.t()},
          required(:output_name) => String.t(),
          required(:graph_summary) => map()
        }

  @spec compile(WorkflowBlueprint.t() | map(), Workspace.t(), keyword()) ::
          {:ok, compiled()} | {:error, Error.t()}
  def compile(blueprint_input, %Workspace{} = workspace, opts \\ []) when is_list(opts) do
    with {:ok, blueprint} <- WorkflowBlueprint.from_input(blueprint_input),
         {:ok, report} <- BlueprintValidator.validate(blueprint, validation_opts(opts)),
         {:ok, ordered} <- topological_order(blueprint),
         {:ok, context} <- initial_context(workspace, blueprint, opts) do
      node_names =
        blueprint.components
        |> Enum.with_index(1)
        |> Map.new(fn {component, index} ->
          {component.id, "assistant_node_#{index}_#{safe_name(component.id)}"}
        end)

      input_name = "assistant_input"

      input_step =
        Runic.step(fn input -> Map.put(context, :input, input || %{}) end,
          name: input_name
        )

      compile_opts = Keyword.put(opts, :node_names, node_names)

      workflow =
        ordered
        |> Enum.reduce(
          Workflow.new(name: "assistant_rlm:#{safe_name(blueprint.id)}")
          |> Workflow.add(input_step),
          fn component, workflow ->
            parents = parent_ids(component.id, blueprint.edges)

            to =
              if parents == [] do
                input_name
              else
                Enum.map(parents, &Map.fetch!(node_names, &1))
              end

            Workflow.add(workflow, node_step(component, length(List.wrap(to)), compile_opts),
              to: to
            )
          end
        )

      output_name = Map.fetch!(node_names, output_component_id(blueprint, ordered))

      {:ok,
       %{
         workflow: workflow,
         blueprint: blueprint,
         validation_report: report,
         ordered_components: ordered,
         node_names: node_names,
         output_name: output_name,
         graph_summary: graph_summary(blueprint, ordered)
       }}
    end
  end

  @spec run(WorkflowBlueprint.t() | map(), Workspace.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(blueprint_input, %Workspace{} = workspace, input \\ %{}, opts \\ [])
      when is_map(input) and is_list(opts) do
    with {:ok, compiled} <- compile(blueprint_input, workspace, opts),
         {:ok, context} <- execute_once(compiled, workspace, input, opts) do
      {:ok,
       %{
         blueprint: compiled.blueprint,
         proposal: compiled.blueprint,
         validation_report: compiled.validation_report,
         compiled: Map.drop(compiled, [:workflow, :ordered_components]),
         workflow: compiled.workflow,
         context: context,
         output: latest_output(context),
         artifacts: Map.get(context || %{}, :artifacts, []),
         trace: Map.get(context || %{}, :trace, []),
         episodes: Map.get(context || %{}, :episodes, []),
         scorecard: latest_scorecard(context)
       }}
    end
  end

  @spec result(compiled(), Workflow.t()) :: map()
  def result(compiled, %Workflow{} = workflow) do
    context = workflow |> Workflow.raw_productions(compiled.output_name) |> List.last()

    %{
      blueprint: compiled.blueprint,
      proposal: compiled.blueprint,
      validation_report: compiled.validation_report,
      compiled: Map.drop(compiled, [:workflow]),
      workflow: workflow,
      context: context,
      output: latest_output(context),
      artifacts: Map.get(context || %{}, :artifacts, []),
      trace: Map.get(context || %{}, :trace, []),
      episodes: Map.get(context || %{}, :episodes, []),
      scorecard: latest_scorecard(context)
    }
  end

  defp execute_once(compiled, %Workspace{} = workspace, input, opts) do
    with {:ok, context} <- initial_context(workspace, compiled.blueprint, opts) do
      context = Map.put(context, :input, input || %{})

      compiled.ordered_components
      |> Enum.reduce_while({:ok, context}, fn component, {:ok, context} ->
        case execute_node(component, context, opts) do
          {:ok, context} -> {:cont, {:ok, context}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp initial_context(workspace, blueprint, opts) do
    ExecutionContext.new(workspace, blueprint.objective,
      sources: blueprint.sources,
      policies: blueprint.policies,
      budgets: get(blueprint.policies, :budgets, %{}),
      event_sink: Keyword.get(opts, :event_sink),
      metadata: %{
        run_id: Keyword.get(opts, :run_id),
        model: Keyword.get(opts, :model),
        write_policy: Keyword.get(opts, :write_policy)
      }
    )
    |> case do
      {:ok, context} ->
        {:ok,
         context
         |> Map.from_struct()
         |> Map.put(:blueprint_edges, blueprint.edges)
         |> Map.put(:budget_ledger, BudgetLedger.new!(get(blueprint.policies, :budgets, %{})))
         |> Map.put(:latest_output, nil)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp node_step(component, 1, opts) do
    Runic.step(fn context -> execute_node!(component, merge_contexts([context]), opts) end,
      name: Keyword.fetch!(opts, :node_names) |> Map.fetch!(component.id)
    )
  end

  defp node_step(component, 2, opts) do
    Runic.step(
      fn left, right -> execute_node!(component, merge_contexts([left, right]), opts) end,
      name: Keyword.fetch!(opts, :node_names) |> Map.fetch!(component.id)
    )
  end

  defp node_step(component, 3, opts) do
    Runic.step(fn a, b, c -> execute_node!(component, merge_contexts([a, b, c]), opts) end,
      name: Keyword.fetch!(opts, :node_names) |> Map.fetch!(component.id)
    )
  end

  defp node_step(component, _parent_count, opts) do
    Runic.step(fn a, b, c, d -> execute_node!(component, merge_contexts([a, b, c, d]), opts) end,
      name: Keyword.fetch!(opts, :node_names) |> Map.fetch!(component.id)
    )
  end

  defp execute_node!(%ComponentBlueprint{} = component, context, opts) do
    case execute_node(component, context, opts) do
      {:ok, context} -> context
      {:error, %Error{} = error} -> raise ArgumentError, error.message
    end
  end

  defp execute_node(%ComponentBlueprint{} = component, context, opts) do
    emit_stage(context, :node_started, :running, %{
      node_id: component.id,
      type: component.type
    })

    with {:ok, output} <- dispatch(component, context, opts),
         {:ok, context} <- record_budget(context, component, output) do
      context =
        context
        |> put_in([:outputs, component.id], output)
        |> Map.put(:latest_output, output)
        |> record_output(component, output)
        |> update_in([:episodes], &append(&1, episode(component, :satisfied, output)))
        |> update_in([:trace], &append(&1, trace(component, :satisfied)))

      emit_stage(context, :node_completed, :ok, %{
        node_id: component.id,
        type: component.type,
        output: output_summary(output)
      })

      {:ok, context}
    else
      {:error, %Error{} = error} ->
        emit_stage(context, :node_failed, :error, %{
          node_id: component.id,
          type: component.type,
          error: error
        })

        {:error, error}
    end
  end

  defp dispatch(
         %ComponentBlueprint{type: :source_discovery, params: params} = component,
         context,
         _opts
       ) do
    SourceDiscovery.run(context.workspace, source_input(component, context, params), params)
  end

  defp dispatch(
         %ComponentBlueprint{type: :source_splitter, params: params} = component,
         context,
         _opts
       ) do
    SourceSplitter.run(context.workspace, source_input(component, context, params), params)
  end

  defp dispatch(
         %ComponentBlueprint{type: :source_materializer, params: params} = component,
         context,
         _opts
       ) do
    SourceMaterializer.run(parent_input(component, context), params)
  end

  defp dispatch(
         %ComponentBlueprint{type: :tabular_parser, params: params} = component,
         context,
         _opts
       ) do
    TabularParser.run(parent_input(component, context), params, workspace: context.workspace)
  end

  defp dispatch(%ComponentBlueprint{type: :llm_map, params: params} = component, context, opts) do
    LLMMap.run(parent_input(component, context), params, llm_component_opts(context, opts))
  end

  defp dispatch(%ComponentBlueprint{type: :record_map, params: params} = component, context, opts) do
    RecordMap.run(parent_input(component, context), params, llm_component_opts(context, opts))
  end

  defp dispatch(
         %ComponentBlueprint{type: :record_group, params: params} = component,
         context,
         opts
       ) do
    RecordGroup.run(parent_input(component, context), params,
      max_tier: max_function_tier(context, opts)
    )
  end

  defp dispatch(
         %ComponentBlueprint{type: :document_compare, params: params} = component,
         context,
         _opts
       ) do
    DocumentCompare.run(parent_input(component, context), params, workspace: context.workspace)
  end

  defp dispatch(%ComponentBlueprint{type: :llm_leaf, params: params} = component, context, opts) do
    parent = parent_input(component, context)

    HierarchicalReduce.run(
      parent,
      Map.put(params, :strategy, :llm_reduce),
      llm_component_opts(context, opts)
    )
  end

  defp dispatch(
         %ComponentBlueprint{type: :report_composer, params: params} = component,
         context,
         _opts
       ) do
    ReportComposer.run(parent_input(component, context), params)
  end

  defp dispatch(
         %ComponentBlueprint{type: :blueprint_transform, params: params} = component,
         context,
         opts
       ) do
    function = get(params, :function, %{tier: :tier0, op: :identity})

    BlueprintTransform.apply(function, parent_input(component, context),
      max_tier: max_function_tier(context, opts)
    )
  end

  defp dispatch(
         %ComponentBlueprint{type: :blueprint_reduce, params: params} = component,
         context,
         opts
       ) do
    case get(params, :function, nil) do
      nil ->
        HierarchicalReduce.run(
          parent_input(component, context),
          Map.put(params, :strategy, :join),
          opts
        )

      function ->
        BlueprintTransform.apply(function, parent_input(component, context),
          max_tier: max_function_tier(context, opts)
        )
    end
  end

  defp dispatch(
         %ComponentBlueprint{type: :artifact_writer, params: params} = component,
         context,
         opts
       ) do
    params =
      params
      |> Map.put_new(
        :write_policy,
        Keyword.get(opts, :write_policy, get(context.policies, :write_policy, :docs_only))
      )

    ArtifactWriter.run(context.workspace, parent_input(component, context), params)
  end

  defp dispatch(
         %ComponentBlueprint{type: type, params: params} = component,
         context,
         _opts
       )
       when type in [:verification, :objective_scorecard] do
    ObjectiveScorecard.run(context.workspace, context, parent_input(component, context), params)
  end

  defp dispatch(%ComponentBlueprint{type: :budget_ledger, params: params}, context, _opts) do
    BudgetLedger.run(context, params)
  end

  defp dispatch(%ComponentBlueprint{type: type}, _context, _opts) do
    {:error,
     Error.validation("unsupported assistant component type",
       source: __MODULE__,
       details: %{type: type}
     )}
  end

  defp record_output(context, %ComponentBlueprint{type: :artifact_writer}, output) do
    update_in(context, [:artifacts], &append(&1, output))
  end

  defp record_output(context, %ComponentBlueprint{type: type}, output)
       when type in [:verification, :objective_scorecard] do
    update_in(context, [:scorecards], &append(&1, output))
  end

  defp record_output(context, _component, _output), do: context

  defp latest_output(nil), do: nil
  defp latest_output(context), do: Map.get(context, :latest_output)

  defp latest_scorecard(nil), do: nil
  defp latest_scorecard(context), do: List.last(context.scorecards || [])

  defp record_budget(context, %ComponentBlueprint{} = component, output) do
    case BudgetLedger.record(Map.get(context, :budget_ledger), component, output) do
      {:ok, ledger} -> {:ok, Map.put(context, :budget_ledger, ledger)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp source_input(component, context, params) do
    explicit = get(params, :sources, nil) || get(params, :paths, nil) || get(params, :globs, nil)

    cond do
      not is_nil(explicit) ->
        List.wrap(explicit)

      match?(%ComponentBlueprint{}, component) and parent_outputs(component, context) != [] ->
        parent_input(component, context)

      true ->
        context.sources
    end
  end

  defp parent_input(%ComponentBlueprint{} = component, context) do
    parents = parent_ids(component.id, context.blueprint_edges || context[:blueprint_edges] || [])

    case parent_outputs(component, context) do
      [single] when length(parents) <= 1 -> single
      outputs -> outputs
    end
  end

  defp parent_outputs(%ComponentBlueprint{} = component, context) do
    component.inputs
    |> case do
      [] -> parent_ids(component.id, context.blueprint_edges || [])
      inputs -> inputs
    end
    |> Enum.map(&Map.get(context.outputs, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp merge_contexts(contexts) do
    contexts
    |> List.wrap()
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn context, acc ->
      acc
      |> Map.merge(context, fn
        :outputs, left, right -> Map.merge(left || %{}, right || %{})
        :artifacts, left, right -> Enum.uniq((left || []) ++ (right || []))
        :trace, left, right -> Enum.uniq((left || []) ++ (right || []))
        :episodes, left, right -> Enum.uniq((left || []) ++ (right || []))
        :scorecards, left, right -> Enum.uniq((left || []) ++ (right || []))
        _key, _left, right -> right
      end)
    end)
  end

  defp topological_order(%WorkflowBlueprint{} = blueprint) do
    by_id = Map.new(blueprint.components, &{&1.id, &1})
    ids = WorkflowBlueprint.component_ids(blueprint)
    incoming = Map.new(ids, &{&1, parent_ids(&1, blueprint.edges)})
    roots = Enum.filter(ids, &(Map.get(incoming, &1, []) == []))

    build_order(roots, incoming, blueprint.edges, by_id, [])
    |> case do
      {:ok, ordered} when length(ordered) == length(ids) ->
        {:ok, ordered}

      {:ok, _ordered} ->
        {:error,
         Error.validation("assistant workflow graph contains a cycle", source: __MODULE__)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_order([], _incoming, _edges, _by_id, ordered), do: {:ok, Enum.reverse(ordered)}

  defp build_order([id | queue], incoming, edges, by_id, ordered) do
    children = edges |> Enum.filter(&(&1.from == id)) |> Enum.map(& &1.to)

    {incoming, queue} =
      Enum.reduce(children, {incoming, queue}, fn child, {incoming, queue} ->
        next_parents = incoming |> Map.get(child, []) |> List.delete(id)
        incoming = Map.put(incoming, child, next_parents)

        queue =
          if next_parents == [] and child not in queue do
            queue ++ [child]
          else
            queue
          end

        {incoming, queue}
      end)

    build_order(queue, incoming, edges, by_id, [Map.fetch!(by_id, id) | ordered])
  end

  defp output_component_id(%WorkflowBlueprint{} = blueprint, ordered) do
    parent_ids =
      blueprint.edges
      |> Enum.map(& &1.from)
      |> MapSet.new()

    ordered
    |> Enum.reject(&MapSet.member?(parent_ids, &1.id))
    |> List.last()
    |> case do
      nil -> List.last(ordered).id
      component -> component.id
    end
  end

  defp parent_ids(id, edges) do
    edges
    |> Enum.filter(&(&1.to == id))
    |> Enum.map(& &1.from)
  end

  defp graph_summary(%WorkflowBlueprint{} = blueprint, ordered) do
    %{
      id: blueprint.id,
      objective: blueprint.objective,
      nodes:
        Enum.map(ordered, fn component ->
          %{
            id: component.id,
            type: component.type,
            inputs: parent_ids(component.id, blueprint.edges),
            outputs: component.outputs
          }
        end),
      edges: blueprint.edges,
      stop_conditions: blueprint.stop_conditions
    }
  end

  defp output_summary(output) do
    cond do
      is_map(output) and Map.has_key?(output, :path) ->
        Map.take(output, [:status, :path, :bytes])

      is_map(output) and Map.has_key?(output, :count) ->
        Map.take(output, [:count, :strategy, :truncated?])

      is_map(output) and Map.has_key?(output, :text) ->
        %{text_preview: preview(output.text)}

      true ->
        %{preview: preview(output)}
    end
  end

  defp episode(component, status, output) do
    %{
      id: "episode:#{component.id}",
      node_id: component.id,
      type: component.type,
      status: status,
      output: output_summary(output)
    }
  end

  defp trace(component, status),
    do: %{node_id: component.id, type: component.type, status: status}

  defp llm_component_opts(context, opts) do
    opts
    |> Keyword.put(:objective, context.objective)
    |> Keyword.put(:model, Keyword.get(opts, :model) || @default_model)
  end

  defp validation_opts(opts) do
    [
      max_generated_function_tier: Keyword.get(opts, :max_generated_function_tier, :tier1),
      max_nodes: Keyword.get(opts, :max_nodes)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp max_function_tier(context, opts) do
    Keyword.get(opts, :max_generated_function_tier) ||
      get_in(context.policies, [:generated_functions, :max_tier]) ||
      get_in(context.policies, ["generated_functions", "max_tier"]) ||
      :tier1
  end

  defp emit_stage(context, stage, status, data) do
    sink = context.event_sink

    if is_function(sink, 1) do
      try do
        sink.(%{
          run_id: get_in(context, [:metadata, :run_id]),
          stage: stage,
          status: status,
          data: data
        })
      rescue
        _exception -> :ok
      end
    end

    :ok
  end

  defp preview(value) when is_binary(value) do
    if String.length(value) > 220, do: String.slice(value, 0, 220) <> "...", else: value
  end

  defp preview(value), do: inspect(value, limit: 12, printable_limit: 220)

  defp append(nil, value), do: [value]
  defp append(values, value) when is_list(values), do: values ++ [value]

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

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
