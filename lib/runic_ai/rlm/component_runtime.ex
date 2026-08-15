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
  alias RunicAI.Agent.CapabilityResolver
  alias RunicAI.Agent.ToolExecution
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentError
  alias RunicAI.RLM.Components.ArtifactWriter
  alias RunicAI.RLM.Components.ArtifactMaterializer
  alias RunicAI.RLM.Components.BlueprintTransform
  alias RunicAI.RLM.Components.BudgetLedger
  alias RunicAI.RLM.Components.DocumentCompare
  alias RunicAI.RLM.Components.HierarchicalReduce
  alias RunicAI.RLM.Components.LLMMap
  alias RunicAI.RLM.Components.ObjectiveScorecard
  alias RunicAI.RLM.Components.RecordGroup
  alias RunicAI.RLM.Components.RecordMap
  alias RunicAI.RLM.Components.ReportComposer
  alias RunicAI.RLM.Components.SafeCompute
  alias RunicAI.RLM.Components.SourceDiscovery
  alias RunicAI.RLM.Components.SourceMaterializer
  alias RunicAI.RLM.Components.SourceSplitter
  alias RunicAI.RLM.Components.TabularParser
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.TaskKind
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Persistence.WorkflowTask

  @default_model "openai:gpt-5.4-mini"
  @sandbox_execute_argument_keys [
    :session_id,
    "session_id",
    :runtime,
    "runtime",
    :code,
    "code",
    :timeout_ms,
    "timeout_ms",
    :max_output_bytes,
    "max_output_bytes",
    :files,
    "files",
    :network,
    "network"
  ]

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
         write_policy: Keyword.get(opts, :write_policy),
         capability_profile: Keyword.get(opts, :capability_profile)
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
        :lambda_map -> LLMMap.items(input, params)
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

    opts =
      base
      |> llm_component_opts(runtime_opts(runtime))
      |> component_llm_opts(component)

    result =
      case component.type do
        :llm_map ->
          LLMMap.map_item(envelope.item, envelope.index, envelope.input, params, opts)

        :lambda_map ->
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

  defp dispatch(%ComponentBlueprint{type: :llm_map, params: params} = component, input, runtime) do
    base = runtime_context(runtime)

    opts =
      base
      |> llm_component_opts(runtime_opts(runtime))
      |> component_llm_opts(component)

    LLMMap.run(input, params, opts)
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

  defp dispatch(%ComponentBlueprint{type: type, params: params}, input, runtime)
       when type in [
              :collection_compute,
              :string_compute,
              :json_compute,
              :artifact_compute,
              :time_compute,
              :score_compute
            ] do
    base = runtime_context(runtime)

    SafeCompute.run(type, input, params,
      workspace: base.workspace,
      max_tier: max_function_tier(base, runtime_opts(runtime))
    )
  end

  defp dispatch(%ComponentBlueprint{type: :artifact_materializer, params: params}, input, runtime) do
    base = runtime_context(runtime)
    ArtifactMaterializer.run(base.workspace, input, params)
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_status, params: params}, input, runtime) do
    execute_capability_tool(
      "sandbox_status",
      sandbox_status_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_execute, params: params}, input, runtime) do
    execute_capability_tool(
      "execute_code",
      sandbox_execute_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_open_session, params: params}, input, runtime) do
    execute_capability_tool(
      "open_sandbox_session",
      tool_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_session_exec, params: params}, input, runtime) do
    execute_capability_tool(
      "sandbox_exec",
      sandbox_session_arguments(params, input) |> sandbox_execute_arguments(input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_write_file, params: params}, input, runtime) do
    execute_capability_tool(
      "sandbox_write_file",
      sandbox_session_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_read_file, params: params}, input, runtime) do
    execute_capability_tool(
      "sandbox_read_file",
      sandbox_session_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_list_files, params: params}, input, runtime) do
    execute_capability_tool(
      "sandbox_list_files",
      sandbox_session_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_checkpoint, params: params}, input, runtime) do
    execute_capability_tool(
      "checkpoint_sandbox",
      sandbox_session_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_restore, params: params}, input, runtime) do
    execute_capability_tool(
      "restore_sandbox",
      sandbox_session_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_close_session, params: params}, input, runtime) do
    execute_capability_tool(
      "close_sandbox_session",
      sandbox_session_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_start_service, params: params}, input, runtime) do
    execute_capability_tool(
      "start_sandbox_service",
      sandbox_session_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_stop_service, params: params}, input, runtime) do
    execute_capability_tool(
      "stop_sandbox_service",
      sandbox_service_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_list_services, params: params}, input, runtime) do
    execute_capability_tool(
      "list_sandbox_services",
      sandbox_session_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_open_proxy, params: params}, input, runtime) do
    execute_capability_tool(
      "open_sandbox_proxy",
      sandbox_service_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :sandbox_close_proxy, params: params}, input, runtime) do
    execute_capability_tool(
      "close_sandbox_proxy",
      sandbox_proxy_arguments(params, input),
      params,
      input,
      runtime
    )
  end

  defp dispatch(%ComponentBlueprint{type: :lambda_plan, params: params}, input, runtime) do
    base = runtime_context(runtime)
    objective = get(params, :objective, nil) || base.objective
    task_kind = get(params, :task_kind, get(params, :task_type, :summarization))
    source_refs = lambda_source_refs(input, params)

    with {:ok, task_kind} <- normalize_task_kind(task_kind),
         :ok <- require_lambda_source_refs(source_refs, params) do
      RunicAI.RLM.lambda_plan(objective, task_kind, source_refs,
        policy: get(params, :policy, nil),
        probes: get(params, :probes, []),
        metadata: %{component_id: get(params, :component_id, nil)}
      )
    end
  end

  defp dispatch(%ComponentBlueprint{type: :lambda_split, params: params}, input, runtime) do
    base = runtime_context(runtime)
    SourceSplitter.run(base.workspace, source_input(input, base, params), params)
  end

  defp dispatch(
         %ComponentBlueprint{type: :lambda_map, params: params} = component,
         input,
         runtime
       ) do
    base = runtime_context(runtime)

    opts =
      base
      |> llm_component_opts(runtime_opts(runtime))
      |> component_llm_opts(component)

    LLMMap.run(input, params, opts)
  end

  defp dispatch(%ComponentBlueprint{type: :lambda_filter}, input, _runtime), do: {:ok, input}

  defp dispatch(%ComponentBlueprint{type: :lambda_reduce, params: params}, input, runtime) do
    HierarchicalReduce.run(input, Map.put_new(params, :strategy, :join), runtime_opts(runtime))
  end

  defp dispatch(%ComponentBlueprint{type: :lambda_cross, params: params}, input, runtime) do
    DocumentCompare.run(input, params, workspace: runtime_context(runtime).workspace)
  end

  defp dispatch(%ComponentBlueprint{type: :lambda_review, params: params}, input, runtime) do
    base = runtime_context(runtime)
    ObjectiveScorecard.run(base.workspace, scorecard_context(base, input), input, params)
  end

  defp dispatch(%ComponentBlueprint{type: :lambda_generate, params: params}, input, _runtime) do
    ReportComposer.run(input, params)
  end

  defp dispatch(%ComponentBlueprint{type: :tool_leaf, params: params}, input, runtime) do
    tool_name = get(params, :tool, nil) || get(params, :name, nil)
    arguments = tool_arguments(params, input)

    with :ok <- require_tool_name(tool_name, params) do
      execute_capability_tool(tool_name, arguments, params, input, runtime)
    end
  end

  defp dispatch(%ComponentBlueprint{type: :llm_leaf, params: params} = component, input, runtime) do
    base = runtime_context(runtime)

    HierarchicalReduce.run(
      input,
      Map.put(params, :strategy, :llm_reduce),
      base
      |> llm_component_opts(runtime_opts(runtime))
      |> component_llm_opts(component)
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

    with :ok <-
           ArtifactWriter.validate_target(
             get(params, :path, nil),
             get(params, :write_policy, :docs_only)
           ),
         {:ok, reviewed_params} <- maybe_review_artifact_write(base, input, params, opts) do
      ArtifactWriter.run(base.workspace, input, reviewed_params)
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

  defp dispatch(
         %ComponentBlueprint{type: :workflow_task, params: params} = component,
         input,
         runtime
       ) do
    opts = runtime_opts(runtime)
    workflow_key = get(params, :workflow_key, nil)

    reference =
      %{
        workflow_key: workflow_key,
        revision: get(params, :revision, nil),
        revision_id: get(params, :revision_id, nil),
        definition_hash: get(params, :definition_hash, nil),
        contract_hash: get(params, :contract_hash, nil)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with store when not is_nil(store) <- Keyword.get(opts, :workflow_store),
         runner when not is_nil(runner) <- Keyword.get(opts, :workflow_runner),
         parent_run_id when is_binary(parent_run_id) <-
           Keyword.get(opts, :workflow_parent_run_id) || Keyword.get(opts, :run_id),
         {:ok, result} <-
           WorkflowTask.invoke(store, parent_run_id, reference, workflow_task_input(input),
             runner: runner,
             parent_node_id: get(params, :parent_node_id, component.id),
             retry_failed?: get(params, :retry_failed?, false),
             timeout: get(params, :timeout_ms, 30_000)
           ) do
      {:ok, result.output}
    else
      nil -> workflow_task_runtime_error(workflow_key)
      false -> workflow_task_runtime_error(workflow_key)
      {:error, _reason} = error -> error
    end
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

  defp require_tool_name(tool_name, _params) when is_binary(tool_name) and tool_name != "",
    do: :ok

  defp require_tool_name(_tool_name, params) do
    {:error,
     Error.validation("tool_leaf requires a tool name",
       source: __MODULE__,
       details: %{params: params}
     )}
  end

  defp workflow_task_runtime_error(workflow_key) do
    {:error,
     Error.validation("workflow_task requires durable store, runner, and parent run context",
       source: __MODULE__,
       details: %{code: :missing_workflow_task_runtime, workflow_key: workflow_key}
     )}
  end

  defp workflow_task_input(%{input: input}) when is_map(input), do: input
  defp workflow_task_input(%{"input" => input}) when is_map(input), do: input
  defp workflow_task_input(input), do: input

  defp execute_capability_tool(tool_name, arguments, params, input, runtime) do
    base = runtime_context(runtime)
    opts = runtime_opts(runtime)

    with {:ok, resolved} <- tool_capabilities(base.workspace, opts) do
      ToolExecution.execute(resolved.registry, tool_name, arguments,
        capability_profile: resolved.profile,
        review_decider: Keyword.get(opts, :review_decider),
        run_id: get(base.metadata, :run_id, nil) || Keyword.get(opts, :run_id),
        session_id: Keyword.get(opts, :session_id),
        context: %{workspace: base.workspace, input: input, params: params}
      )
    end
  end

  defp tool_capabilities(%Workspace{} = workspace, opts) do
    CapabilityResolver.resolve(workspace,
      agent: :assistant,
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
    )
  end

  defp tool_arguments(params, input) do
    params
    |> get(:args, get(params, :arguments, %{}))
    |> case do
      args when is_map(args) -> args
      nil -> %{}
      other -> %{input: input, value: other}
    end
  end

  defp sandbox_status_arguments(params, input) do
    case tool_arguments(params, input) do
      args when map_size(args) > 0 ->
        args

      _empty ->
        params
    end
  end

  defp sandbox_execute_arguments(params, input) do
    params
    |> tool_arguments(input)
    |> Map.merge(Map.drop(params || %{}, [:args, "args", :arguments, "arguments"]))
    |> put_code_from_input(input)
    |> normalize_sandbox_execute_arguments()
  end

  defp sandbox_session_arguments(params, input) do
    params
    |> tool_arguments(input)
    |> Map.merge(Map.drop(params || %{}, [:args, "args", :arguments, "arguments"]))
    |> put_session_id_from_input(input)
  end

  defp put_session_id_from_input(args, input) do
    if present?(get(args, :session_id, nil) || get(args, :id, nil)) do
      args
    else
      case input_session_id(input) do
        nil -> args
        id -> Map.put(args, :session_id, id)
      end
    end
  end

  defp input_session_id(%{session: session}), do: input_session_id(session)
  defp input_session_id(%{"session" => session}), do: input_session_id(session)
  defp input_session_id(%{id: id}) when is_binary(id), do: id
  defp input_session_id(%{"id" => id}) when is_binary(id), do: id
  defp input_session_id(%{session_id: id}) when is_binary(id), do: id
  defp input_session_id(%{"session_id" => id}) when is_binary(id), do: id
  defp input_session_id(_input), do: nil

  defp sandbox_service_arguments(params, input) do
    params
    |> sandbox_session_arguments(input)
    |> put_service_id_from_input(input)
  end

  defp put_service_id_from_input(args, input) do
    if present?(get(args, :service_id, nil)) do
      args
    else
      case input_service_id(input) do
        nil -> args
        id -> Map.put(args, :service_id, id)
      end
    end
  end

  defp input_service_id(%{service: service}), do: input_service_id(service)
  defp input_service_id(%{"service" => service}), do: input_service_id(service)
  defp input_service_id(%{service_id: id}) when is_binary(id), do: id
  defp input_service_id(%{"service_id" => id}) when is_binary(id), do: id
  defp input_service_id(%{id: id}) when is_binary(id), do: id
  defp input_service_id(%{"id" => id}) when is_binary(id), do: id
  defp input_service_id(_input), do: nil

  defp sandbox_proxy_arguments(params, input) do
    params
    |> tool_arguments(input)
    |> Map.merge(Map.drop(params || %{}, [:args, "args", :arguments, "arguments"]))
    |> put_proxy_id_from_input(input)
  end

  defp put_proxy_id_from_input(args, input) do
    if present?(get(args, :proxy_id, nil)) do
      args
    else
      case input_proxy_id(input) do
        nil -> args
        id -> Map.put(args, :proxy_id, id)
      end
    end
  end

  defp input_proxy_id(%{proxy: proxy}), do: input_proxy_id(proxy)
  defp input_proxy_id(%{"proxy" => proxy}), do: input_proxy_id(proxy)
  defp input_proxy_id(%{proxy_id: id}) when is_binary(id), do: id
  defp input_proxy_id(%{"proxy_id" => id}) when is_binary(id), do: id
  defp input_proxy_id(%{id: id}) when is_binary(id), do: id
  defp input_proxy_id(%{"id" => id}) when is_binary(id), do: id
  defp input_proxy_id(_input), do: nil

  defp normalize_sandbox_execute_arguments(args) do
    args = Map.take(args, @sandbox_execute_argument_keys)

    case get(args, :runtime, nil) do
      runtime when is_atom(runtime) -> Map.put(args, :runtime, Atom.to_string(runtime))
      _runtime -> args
    end
  end

  defp put_code_from_input(args, input) do
    if present?(get(args, :code, nil) || get(args, :source, nil)) do
      args
    else
      case input_code(input) do
        nil -> args
        code -> Map.put(args, :code, code)
      end
    end
  end

  defp input_code(%{code: code}) when is_binary(code), do: code
  defp input_code(%{"code" => code}) when is_binary(code), do: code
  defp input_code(%{source: code}) when is_binary(code), do: code
  defp input_code(%{"source" => code}) when is_binary(code), do: code
  defp input_code(code) when is_binary(code), do: code
  defp input_code(_input), do: nil

  defp lambda_source_refs(input, params) do
    source_refs =
      get(params, :source_refs, nil) ||
        get(params, :sources, nil) ||
        get(input, :source_refs, nil) ||
        get(input, :sources, [])

    source_refs
    |> List.wrap()
    |> Enum.filter(&match?(%EnvironmentRef{}, &1))
  end

  defp require_lambda_source_refs([_first | _rest], _params), do: :ok

  defp require_lambda_source_refs(source_refs, params) do
    {:error,
     Error.validation("lambda_plan requires EnvironmentRef source refs",
       source: __MODULE__,
       details: %{source_refs: source_refs, params: params}
     )}
  end

  defp normalize_task_kind(task_kind) when is_atom(task_kind) do
    if TaskKind.valid?(task_kind) do
      {:ok, task_kind}
    else
      invalid_task_kind(task_kind)
    end
  end

  defp normalize_task_kind(task_kind) when is_binary(task_kind) do
    TaskKind.valid_kinds()
    |> Enum.find(&(Atom.to_string(&1) == task_kind))
    |> case do
      nil -> invalid_task_kind(task_kind)
      task_kind -> {:ok, task_kind}
    end
  end

  defp normalize_task_kind(task_kind), do: invalid_task_kind(task_kind)

  defp invalid_task_kind(task_kind) do
    {:error,
     Error.validation("invalid lambda_plan task kind",
       source: __MODULE__,
       details: %{task_kind: task_kind, valid_kinds: TaskKind.valid_kinds()}
     )}
  end

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
    run_id = get(base.metadata, :run_id, nil) || Keyword.get(opts, :run_id)
    session_id = Keyword.get(opts, :session_id) || run_id

    opts
    |> Keyword.put(:objective, llm_objective(base, opts))
    |> Keyword.put(
      :model,
      Keyword.get(opts, :model) || get(base.metadata, :model, nil) || @default_model
    )
    |> maybe_put(:stream_sink, llm_stream_sink(base))
    |> maybe_put(:run_id, run_id)
    |> maybe_put(:session_id, session_id)
    |> Keyword.put_new(:agent, Keyword.get(opts, :agent, :assistant))
    |> maybe_put(:presentation_group_id, run_id || session_id)
  end

  defp component_llm_opts(opts, %ComponentBlueprint{} = component) do
    opts
    |> maybe_put(:model, get(component.params, :model, nil))
    |> Keyword.put(:component_id, component.id)
    |> Keyword.put(:component_type, component.type)
    |> Keyword.put_new(:workflow_node, component.id)
    |> Keyword.put_new(:source_step, component.type)
  end

  defp llm_stream_sink(base) do
    sink = get(base, :event_sink, nil)

    if is_function(sink, 1) do
      fn stage -> sink.(stage) end
    end
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp llm_objective(base, opts) do
    objective = to_string(base.objective || "")

    if reviewed_artifact_write?(opts) do
      strip_runtime_review_instructions(objective)
    else
      objective
    end
  end

  defp reviewed_artifact_write?(opts) do
    is_function(Keyword.get(opts, :review_decider), 2) and
      present?(Keyword.get(opts, :output_path))
  end

  defp strip_runtime_review_instructions(objective) do
    objective
    |> String.replace(
      ~r/\s*(?:wait|pause)\s+for\s+(?:browser\s+)?approval\s+before\s+writing[.!]?/i,
      ""
    )
    |> String.replace(
      ~r/\s*(?:continue|write|persist|save)\s+only\s+after\s+(?:browser\s+)?approval[.!]?/i,
      ""
    )
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

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
            {:ok, params}

          {:ok, %ReviewDecision{status: :edited} = decision} ->
            emit_stage(base, :review_completed, :ok, review_event_data(request, decision))
            {:ok, apply_artifact_write_edit(params, decision)}

          {:ok, %ReviewDecision{status: status} = decision}
          when status in [:rejected, :cancelled] ->
            emit_stage(base, :review_completed, :blocked, review_event_data(request, decision))
            artifact_write_review_denied(request, decision)

          {:error, %Error{} = error} ->
            {:error, error}

          {:error, reason} ->
            {:error, Error.from_reason(reason, source: __MODULE__)}
        end

      _other ->
        {:ok, params}
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
        suggested_paths: suggested_write_paths(write_policy, path),
        input_preview: output_summary(input)
      },
      metadata: %{
        safe?: docs_only?,
        component_type: :artifact_writer,
        risk: if(docs_only?, do: :low, else: :medium)
      }
    )
  end

  defp suggested_write_paths(write_policy, path)
       when write_policy in [:docs_only, "docs_only", "docs-only"] do
    basename =
      case path do
        path when is_binary(path) and path != "" -> Path.basename(path)
        _other -> "assistant-report.md"
      end

    [Path.join(".docs", basename)]
  end

  defp suggested_write_paths(_write_policy, _path), do: []

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
      metadata: decision.metadata,
      edited_value: decision.edited_value
    })
  end

  defp artifact_write_review_denied(%ReviewRequest{} = request, %ReviewDecision{} = decision) do
    reason = artifact_not_written_reason(decision.status)
    outcome = artifact_not_written_outcome(reason, request.details)

    {:error,
     Error.validation(artifact_write_review_message(reason),
       source: __MODULE__,
       details: %{
         path: request.details[:path],
         resume_key: request.resume_key,
         decision_status: decision.status,
         review_request: review_request_payload(request),
         suggested_paths: request.details[:suggested_paths] || [],
         artifact_outcome: outcome
       }
     )}
  end

  defp review_request_payload(%ReviewRequest{} = request) do
    %{
      kind: request.kind,
      subject: request.subject,
      checkpoint: request.checkpoint,
      resume_key: request.resume_key,
      options: request.options,
      details: request.details,
      metadata: request.metadata
    }
  end

  defp apply_artifact_write_edit(params, %ReviewDecision{edited_value: edited})
       when is_binary(edited) do
    if String.trim(edited) == "" do
      params
    else
      Map.put(params, :content, edited)
    end
  end

  defp apply_artifact_write_edit(params, %ReviewDecision{edited_value: edited})
       when is_map(edited) do
    Map.merge(params, edited)
  end

  defp apply_artifact_write_edit(params, _decision), do: params

  defp artifact_not_written_reason(:rejected), do: "denied"
  defp artifact_not_written_reason(:cancelled), do: "cancelled"
  defp artifact_not_written_reason(status), do: to_string(status)

  defp artifact_write_review_message("cancelled"), do: "artifact write cancelled by review"
  defp artifact_write_review_message(_reason), do: "artifact write denied by review"

  defp artifact_not_written_outcome(reason, details) do
    %{
      status: "artifact_not_written",
      reason: reason,
      path: details[:path],
      suggested_paths: details[:suggested_paths] || []
    }
  end

  defp output_summary(output) do
    cond do
      is_map(output) and Map.has_key?(output, :path) ->
        Map.take(output, [:status, :path, :bytes])

      is_map(output) and Map.has_key?(output, :text) ->
        %{text_preview: preview(output.text)}

      is_map(output) and Map.has_key?(output, :count) ->
        Map.take(output, [:count, :strategy, :truncated?])

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
