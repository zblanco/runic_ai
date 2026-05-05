defmodule RunicAI.RLM.ComponentRuntime do
  @moduledoc """
  Runtime adapter for normalized RLM component specs.

  The compiler builds Runic components as data and Runic owns graph traversal,
  joins, fan-out, fan-in, scheduling, and runnable execution. This module is the
  thin boundary that invokes existing RunicAI component modules against Runic
  facts plus per-node `run_context`.
  """

  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentError
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
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest

  @default_model "openai:gpt-5.4-mini"

  @spec initial_context(Workspace.t(), WorkflowBlueprint.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def initial_context(%Workspace{} = workspace, %WorkflowBlueprint{} = blueprint, opts \\ [])
      when is_list(opts) do
    {:ok,
     %{
       workspace: workspace,
       objective: Keyword.get(opts, :objective, blueprint.objective),
       sources: blueprint.sources,
       policies: blueprint.policies,
       budgets: get(blueprint.policies, :budgets, %{}),
       metadata: %{
         blueprint_id: blueprint.id,
         run_id: Keyword.get(opts, :run_id),
         model: Keyword.get(opts, :model),
         write_policy: Keyword.get(opts, :write_policy)
       },
       event_sink: Keyword.get(opts, :event_sink),
       opts: opts
     }}
  end

  @spec initialize(term(), map()) :: map()
  def initialize(input, runtime) when is_map(runtime) do
    base = runtime_context(runtime)

    %{
      input: input || %{},
      objective: base.objective,
      sources: base.sources,
      policies: base.policies,
      metadata: base.metadata
    }
  end

  @spec run(term(), map()) :: term()
  def run(input, runtime) when is_map(runtime) do
    component = Map.fetch!(runtime, :component)
    execute_node!(component, component_input(input), runtime)
  end

  @spec native_map_items(term(), map()) :: [map()]
  def native_map_items(input, runtime) when is_map(runtime) do
    component = Map.fetch!(runtime, :component)
    params = component.params || %{}
    base = runtime_context(runtime)
    input = component_input(input)

    items =
      case component.type do
        :llm_map -> LLMMap.items(input, params)
        :record_map -> RecordMap.items(input, params)
        :blueprint_transform -> transform_items(input, params)
      end

    Enum.map(items, fn {item, index} ->
      %{
        component_id: component.id,
        component_type: component.type,
        index: index,
        item: item,
        input: input,
        objective: base.objective
      }
    end)
  end

  @spec native_map_item!(map(), map()) :: map()
  def native_map_item!(envelope, runtime) when is_map(envelope) and is_map(runtime) do
    component = native_component!(envelope, runtime)
    base = runtime_context(runtime)
    params = component.params || %{}
    opts = llm_component_opts(base, runtime_opts(runtime))

    result =
      case component.type do
        :llm_map ->
          LLMMap.map_item(envelope.item, envelope.index, envelope.input, params, opts)

        :record_map ->
          RecordMap.map_item(
            envelope.item,
            envelope.index,
            envelope.input,
            params,
            Keyword.put(opts, :max_tier, max_function_tier(base, runtime_opts(runtime)))
          )

        :blueprint_transform ->
          function = get(params, :function, %{tier: :tier0, op: :identity})

          BlueprintTransform.apply(function, envelope.item,
            max_tier: max_function_tier(base, runtime_opts(runtime))
          )
      end

    case result do
      {:ok, item} ->
        %{
          component_id: component.id,
          component_type: component.type,
          index: envelope.index,
          item: item
        }

      {:error, %Error{} = error} ->
        raise ComponentError, error: error, component: component
    end
  end

  @spec native_reduce_init() :: map()
  def native_reduce_init, do: %{items: [], count: 0}

  @spec native_reduce_item(term(), map()) :: map()
  def native_reduce_item(item, acc) do
    value =
      case item do
        %{item: mapped} -> mapped
        %{"item" => mapped} -> mapped
        other -> other
      end

    acc
    |> Map.update(:items, [value], &(&1 ++ [value]))
    |> Map.update(:count, 1, &(&1 + 1))
  end

  @spec native_reduce_finalize!(term(), map()) :: term()
  def native_reduce_finalize!(aggregate, runtime) when is_map(runtime) do
    component = Map.fetch!(runtime, :component)
    execute_node!(component, component_input(aggregate), runtime)
  end

  @spec execute_node!(ComponentBlueprint.t(), term(), map()) :: term()
  def execute_node!(%ComponentBlueprint{} = component, input, runtime) when is_map(runtime) do
    case execute_node(component, input, runtime) do
      {:ok, output} -> output
      {:error, %Error{} = error} -> raise ComponentError, error: error, component: component
    end
  end

  @spec execute_node(ComponentBlueprint.t(), term(), map()) :: {:ok, term()} | {:error, Error.t()}
  def execute_node(%ComponentBlueprint{} = component, input, runtime) when is_map(runtime) do
    base = runtime_context(runtime)
    emit_stage(base, :node_started, :running, %{node_id: component.id, type: component.type})

    case dispatch(component, input, runtime) do
      {:ok, output} ->
        emit_stage(base, :node_completed, :ok, %{
          node_id: component.id,
          type: component.type,
          output: output_summary(output)
        })

        {:ok, output}

      {:error, %Error{} = error} ->
        emit_stage(base, :node_failed, :error, %{
          node_id: component.id,
          type: component.type,
          error: error
        })

        {:error, error}
    end
  end

  defp dispatch(
         %ComponentBlueprint{type: :source_discovery, params: params},
         input,
         runtime
       ) do
    base = runtime_context(runtime)
    SourceDiscovery.run(base.workspace, source_input(input, base, params), params)
  end

  defp dispatch(
         %ComponentBlueprint{type: :source_splitter, params: params},
         input,
         runtime
       ) do
    base = runtime_context(runtime)
    SourceSplitter.run(base.workspace, source_input(input, base, params), params)
  end

  defp dispatch(%ComponentBlueprint{type: :source_materializer, params: params}, input, _runtime) do
    SourceMaterializer.run(input, params)
  end

  defp dispatch(%ComponentBlueprint{type: :tabular_parser, params: params}, input, runtime) do
    TabularParser.run(input, params, workspace: runtime_context(runtime).workspace)
  end

  defp dispatch(%ComponentBlueprint{type: :llm_map, params: params}, input, runtime) do
    base = runtime_context(runtime)
    LLMMap.run(input, params, llm_component_opts(base, runtime_opts(runtime)))
  end

  defp dispatch(%ComponentBlueprint{type: :record_map, params: params}, input, runtime) do
    base = runtime_context(runtime)

    opts =
      base
      |> llm_component_opts(runtime_opts(runtime))
      |> Keyword.put(:max_tier, max_function_tier(base, runtime_opts(runtime)))

    RecordMap.run(input, params, opts)
  end

  defp dispatch(%ComponentBlueprint{type: :record_group, params: params}, input, runtime) do
    base = runtime_context(runtime)
    RecordGroup.run(input, params, max_tier: max_function_tier(base, runtime_opts(runtime)))
  end

  defp dispatch(%ComponentBlueprint{type: :document_compare, params: params}, input, runtime) do
    DocumentCompare.run(input, params, workspace: runtime_context(runtime).workspace)
  end

  defp dispatch(%ComponentBlueprint{type: :llm_leaf, params: params}, input, runtime) do
    base = runtime_context(runtime)

    HierarchicalReduce.run(
      input,
      Map.put(params, :strategy, :llm_reduce),
      llm_component_opts(base, runtime_opts(runtime))
    )
  end

  defp dispatch(%ComponentBlueprint{type: :report_composer, params: params}, input, _runtime) do
    ReportComposer.run(input, params)
  end

  defp dispatch(%ComponentBlueprint{type: :blueprint_transform, params: params}, input, runtime) do
    base = runtime_context(runtime)
    function = get(params, :function, %{tier: :tier0, op: :identity})

    BlueprintTransform.apply(function, input,
      max_tier: max_function_tier(base, runtime_opts(runtime))
    )
  end

  defp dispatch(%ComponentBlueprint{type: :blueprint_reduce, params: params}, input, runtime) do
    base = runtime_context(runtime)

    case get(params, :function, nil) do
      nil ->
        HierarchicalReduce.run(input, Map.put(params, :strategy, :join), runtime_opts(runtime))

      function ->
        BlueprintTransform.apply(function, input,
          max_tier: max_function_tier(base, runtime_opts(runtime))
        )
    end
  end

  defp dispatch(%ComponentBlueprint{type: :artifact_writer, params: params}, input, runtime) do
    base = runtime_context(runtime)
    opts = runtime_opts(runtime)

    params =
      Map.put_new(
        params,
        :write_policy,
        Keyword.get(
          opts,
          :write_policy,
          get(base.policies, :write_policy, :docs_only)
        )
      )

    with :ok <- maybe_review_artifact_write(base, input, params, opts) do
      ArtifactWriter.run(base.workspace, input, params)
    end
  end

  defp dispatch(%ComponentBlueprint{type: type, params: params}, input, runtime)
       when type in [:verification, :objective_scorecard] do
    base = runtime_context(runtime)
    ObjectiveScorecard.run(base.workspace, scorecard_context(base, input), input, params)
  end

  defp dispatch(%ComponentBlueprint{type: :budget_ledger, params: params}, input, runtime) do
    base = runtime_context(runtime)
    BudgetLedger.run(input, Map.merge(base.budgets || %{}, params || %{}))
  end

  defp dispatch(%ComponentBlueprint{type: type}, _input, _runtime) do
    {:error,
     Error.validation("unsupported assistant component type",
       source: __MODULE__,
       details: %{type: type}
     )}
  end

  defp component_input([single]), do: single
  defp component_input(input), do: input

  defp source_input(input, base, params) do
    explicit = get(params, :sources, nil) || get(params, :paths, nil) || get(params, :globs, nil)

    cond do
      not is_nil(explicit) -> List.wrap(explicit)
      input_sources(input) != [] -> input_sources(input)
      true -> base.sources
    end
  end

  defp input_sources(%{sources: sources}) when is_list(sources), do: sources
  defp input_sources(%{"sources" => sources}) when is_list(sources), do: sources
  defp input_sources(values) when is_list(values), do: values
  defp input_sources(_input), do: []

  defp transform_items(input, _params) do
    input
    |> item_values()
    |> Enum.with_index(1)
  end

  defp item_values(%{items: items}) when is_list(items), do: items
  defp item_values(%{"items" => items}) when is_list(items), do: items
  defp item_values(%{records: records}) when is_list(records), do: records
  defp item_values(%{"records" => records}) when is_list(records), do: records
  defp item_values(%{slices: slices}) when is_list(slices), do: slices
  defp item_values(%{"slices" => slices}) when is_list(slices), do: slices
  defp item_values(values) when is_list(values), do: values
  defp item_values(value), do: List.wrap(value)

  defp scorecard_context(base, input) do
    %{
      sources: base.sources,
      policies: base.policies,
      metadata: base.metadata,
      artifacts: collect_type(input, :artifact),
      budget_ledger: budget_ledger(input)
    }
  end

  defp budget_ledger(input) do
    input
    |> flatten_values()
    |> Enum.find(fn
      %{limits: _limits, metrics: _metrics} -> true
      %{"limits" => _limits, "metrics" => _metrics} -> true
      _other -> false
    end)
  end

  defp collect_type(input, :artifact) do
    input
    |> flatten_values()
    |> Enum.filter(fn
      %{path: path, status: status} when is_binary(path) and status in [:written, "written"] ->
        true

      %{"path" => path, "status" => status}
      when is_binary(path) and status in [:written, "written"] ->
        true

      _other ->
        false
    end)
  end

  defp flatten_values(values) when is_list(values), do: Enum.flat_map(values, &flatten_values/1)

  defp flatten_values(%{items: items} = value) when is_list(items),
    do: [value | flatten_values(items)]

  defp flatten_values(%{"items" => items} = value) when is_list(items),
    do: [value | flatten_values(items)]

  defp flatten_values(%{records: records} = value) when is_list(records),
    do: [value | flatten_values(records)]

  defp flatten_values(%{"records" => records} = value) when is_list(records),
    do: [value | flatten_values(records)]

  defp flatten_values(value), do: [value]

  defp native_component!(envelope, runtime) do
    id = get(envelope, :component_id, nil)

    runtime
    |> runtime_context()
    |> get(:components_by_id, %{})
    |> Map.fetch!(id)
  end

  defp runtime_context(%{base_context: base_context}), do: base_context
  defp runtime_context(%{_global: global}), do: global
  defp runtime_context(runtime), do: runtime

  defp runtime_opts(runtime), do: runtime |> get(:opts, []) |> List.wrap()

  defp llm_component_opts(base, opts) do
    opts
    |> Keyword.put(:objective, base.objective)
    |> Keyword.put(
      :model,
      Keyword.get(opts, :model) || get(base.metadata, :model, nil) || @default_model
    )
  end

  defp max_function_tier(base, opts) do
    Keyword.get(opts, :max_generated_function_tier) ||
      get_in(base.policies, [:generated_functions, :max_tier]) ||
      get_in(base.policies, ["generated_functions", "max_tier"]) ||
      :tier1
  end

  defp emit_stage(base, stage, status, data) do
    sink = get(base, :event_sink, nil)

    if is_function(sink, 1) do
      sink.(%{
        run_id: get_in(base, [:metadata, :run_id]),
        stage: stage,
        status: status,
        data: data
      })
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp maybe_review_artifact_write(base, input, params, opts) do
    case Keyword.get(opts, :review_decider) do
      decider when is_function(decider, 2) ->
        request = artifact_write_review_request(base, input, params)
        emit_stage(base, :review_requested, :review, review_event_data(request))

        case decider.(request, %{workspace: base.workspace, input: input, params: params}) do
          {:ok, %ReviewDecision{status: :approved} = decision} ->
            emit_stage(base, :review_completed, :ok, review_event_data(request, decision))
            :ok

          {:ok, %ReviewDecision{status: status} = decision}
          when status in [:rejected, :cancelled, :edited] ->
            emit_stage(base, :review_completed, :blocked, review_event_data(request, decision))
            artifact_write_review_denied(request, decision)

          {:error, %Error{} = error} ->
            {:error, error}

          {:error, reason} ->
            {:error, Error.from_reason(reason, source: __MODULE__)}
        end

      _other ->
        :ok
    end
  end

  defp artifact_write_review_request(base, input, params) do
    path = get(params, :path, nil)
    write_policy = get(params, :write_policy, :docs_only)
    docs_only? = write_policy in [:docs_only, "docs_only", "docs-only"]

    ReviewRequest.new!(:assistant_artifact_write,
      checkpoint: :pre_write,
      resume_key:
        "review:artifact_writer:#{get_in(base.metadata, [:run_id]) || System.unique_integer([:positive])}:#{path || "unknown"}",
      options: [:approve, :reject, :cancel],
      subject: %{path: path, write_policy: write_policy},
      details: %{
        path: path,
        write_policy: write_policy,
        input_preview: output_summary(input)
      },
      metadata: %{
        safe?: docs_only?,
        component_type: :artifact_writer,
        risk: if(docs_only?, do: :low, else: :medium)
      }
    )
  end

  defp review_event_data(%ReviewRequest{} = request) do
    %{
      id: request.resume_key,
      kind: request.kind,
      checkpoint: request.checkpoint,
      resume_key: request.resume_key,
      options: request.options,
      details: request.details,
      metadata: request.metadata
    }
  end

  defp review_event_data(%ReviewRequest{} = request, %ReviewDecision{} = decision) do
    request
    |> review_event_data()
    |> Map.put(:decision, %{
      resume_key: decision.resume_key,
      status: decision.status,
      actor: decision.actor,
      metadata: decision.metadata
    })
  end

  defp artifact_write_review_denied(%ReviewRequest{} = request, %ReviewDecision{} = decision) do
    {:error,
     Error.validation("artifact write denied by review",
       source: __MODULE__,
       details: %{
         path: request.details[:path],
         resume_key: request.resume_key,
         decision_status: decision.status
       }
     )}
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

  defp preview(value) when is_binary(value) do
    if String.length(value) > 220, do: String.slice(value, 0, 220) <> "...", else: value
  end

  defp preview(value), do: inspect(value, limit: 12, printable_limit: 220)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)

  defp get(_map, _key, default), do: default
end
