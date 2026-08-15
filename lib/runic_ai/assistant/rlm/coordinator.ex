defmodule RunicAI.Assistant.RLM.Coordinator do
  @moduledoc """
  General assistant RLM coordinator.

  The coordinator asks an LLM for workflow blueprints as data, validates and
  repairs those blueprints, and falls back to conservative generic workflows
  when generation fails.
  """

  alias RunicAI.Assistant.RLM.BlueprintProposalPrompt
  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.RepairLoop
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.JSONMap
  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.RLM.StrategyRouter
  alias RunicAI.RLM.SubagentAssignment
  alias RunicAI.Sandbox.GeneratedComponentCatalog
  alias RunicAI.Sandbox.GeneratedComponentPromotionFlow
  alias RunicAI.Sandbox.GeneratedComponentWorkflow

  @default_split_bytes 8_000
  @default_model "openai:gpt-5.4-mini"
  @default_generation_mode :json_text
  @component_builder_tools [
    "open_sandbox_session",
    "sandbox_write_file",
    "sandbox_exec",
    "sandbox_read_file",
    "sandbox_list_files",
    "close_sandbox_session"
  ]

  @spec propose(Workspace.t(), String.t(), keyword()) ::
          {:ok, WorkflowBlueprint.t()} | {:error, Error.t()}
  def propose(%Workspace{} = workspace, objective, opts \\ [])
      when is_binary(objective) and objective != "" and is_list(opts) do
    cond do
      Keyword.has_key?(opts, :blueprint) ->
        WorkflowBlueprint.from_input(Keyword.fetch!(opts, :blueprint))

      Keyword.has_key?(opts, :generated_component_proposal) ->
        generated_component_proposal = Keyword.fetch!(opts, :generated_component_proposal)

        opts
        |> generated_component_promotion_flow_opts(objective, generated_component_proposal)
        |> then(&GeneratedComponentPromotionFlow.run(generated_component_proposal, &1))
        |> promotion_flow_blueprint()

      Keyword.has_key?(opts, :generated_components) ->
        GeneratedComponentWorkflow.compose(
          objective,
          Keyword.fetch!(opts, :generated_components),
          generated_component_workflow_opts(opts)
        )

      Keyword.has_key?(opts, :generated_component) ->
        GeneratedComponentWorkflow.compose(
          objective,
          Keyword.fetch!(opts, :generated_component),
          generated_component_workflow_opts(opts)
        )

      generated_component_catalog_reuse?(opts) ->
        case generated_component_catalog_blueprint(objective, opts) do
          {:ok, blueprint} -> {:ok, blueprint}
          :not_found -> continue_without_catalog_reuse(workspace, objective, opts)
          {:error, %Error{} = error} -> {:error, error}
        end

      dynamic_strategy?(opts) ->
        dynamic_blueprint(workspace, objective, opts)

      fallback_strategy?(opts) ->
        fallback_blueprint(workspace, objective, opts)

      routed_strategy?(opts) ->
        routed_blueprint(workspace, objective, opts)

      match?({:ok, _shape}, curated_recipe_shape(workspace, objective, opts)) ->
        {:ok, shape} = curated_recipe_shape(workspace, objective, opts)

        workspace
        |> fallback_blueprint(objective, Keyword.put(opts, :fallback_shape, shape))
        |> tag_curated_recipe(shape)

      evidence_first_default?(opts) ->
        routed_blueprint(workspace, objective, opts)

      true ->
        dynamic_blueprint(workspace, objective, opts)
    end
  end

  @spec fallback_blueprint(Workspace.t(), String.t(), keyword()) ::
          {:ok, WorkflowBlueprint.t()} | {:error, Error.t()}
  def fallback_blueprint(%Workspace{} = workspace, objective, opts \\ []) do
    sources = normalize_sources(Keyword.get(opts, :input_paths, Keyword.get(opts, :inputs, [])))
    output_path = Keyword.get(opts, :output_path)
    write_policy = Keyword.get(opts, :write_policy, :docs_only)
    id = Keyword.get(opts, :blueprint_id) || "assistant:generic_report"
    shape = fallback_shape(workspace, objective, sources, opts)
    opts = maybe_put_recipe_defaults(shape, objective, opts)
    opts = Keyword.put(opts, :comparison_required?, shape == :compare_synthesize_report)
    scorecard_params = scorecard_params(opts, output_path)

    {components, edges, terminal_node} = fallback_graph(shape, sources, opts)

    components =
      components
      |> maybe_append_writer(output_path, write_policy, terminal_node)
      |> append_verification(scorecard_params)

    edges =
      edges
      |> maybe_append_writer_edges(output_path, terminal_node)
      |> append_verification_edges(output_path, terminal_node)

    WorkflowBlueprint.new(objective, components,
      id: id,
      sources: sources,
      edges: edges,
      stop_conditions: stop_conditions(output_path),
      policies: %{
        generated_functions: %{max_tier: Keyword.get(opts, :max_generated_function_tier, :tier1)},
        write_policy: write_policy,
        mutation: %{allowed_paths: allowed_paths(write_policy)},
        budgets: %{
          max_nodes: 12,
          max_llm_calls: Keyword.get(opts, :max_llm_calls, 96),
          max_runtime_ms: Keyword.get(opts, :max_runtime_ms, 900_000)
        }
      },
      metadata: %{
        proposal_kind: shape,
        capability_manifest: capability_manifest(opts)
      }
    )
  end

  @spec capability_manifest(keyword()) :: map()
  def capability_manifest(opts \\ []), do: BlueprintProposalPrompt.manifest(opts)

  @spec prompt(String.t(), Workspace.t(), keyword()) :: String.t()
  def prompt(objective, %Workspace{} = _workspace, opts \\ []) do
    BlueprintProposalPrompt.prompt(
      objective,
      capability_manifest(opts),
      prompt_opts(objective, opts)
    )
  end

  @spec schema() :: keyword()
  def schema, do: BlueprintProposalPrompt.schema()

  @spec route(Workspace.t(), String.t(), keyword()) :: StrategyRouter.t()
  def route(%Workspace{} = workspace, objective, opts \\ [])
      when is_binary(objective) and objective != "" and is_list(opts) do
    StrategyRouter.route(objective, workspace, opts)
  end

  @spec component_builder_assignment(Workspace.t(), String.t(), keyword()) ::
          {:ok, SubagentAssignment.t()} | {:error, Error.t()}
  def component_builder_assignment(%Workspace{} = workspace, objective, opts \\ [])
      when is_binary(objective) and objective != "" and is_list(opts) do
    decision = route(workspace, objective, Keyword.put(opts, :repeated_transform?, true))
    id = Keyword.get(opts, :id, "component_builder:#{System.unique_integer([:positive])}")

    SubagentAssignment.new(
      id: id,
      role: Keyword.get(opts, :role, "component_builder"),
      objective: objective,
      prompt: component_builder_prompt(objective, opts),
      strategy: :generated_sandbox_component,
      agent_kind: :workflow,
      context_slice: Keyword.get(opts, :context_slice),
      capability_profile: Keyword.get(opts, :capability_profile, :local_workbench),
      visible_tools: Keyword.get(opts, :visible_tools, @component_builder_tools),
      budgets: component_builder_budgets(decision, opts),
      output_schema: component_builder_output_schema(),
      review_policy: component_builder_review_policy(opts),
      parent: component_builder_parent(decision, opts),
      metadata: component_builder_metadata(decision, opts)
    )
  end

  @spec enforce_runtime_scorecard_params(WorkflowBlueprint.t(), keyword()) ::
          WorkflowBlueprint.t()
  def enforce_runtime_scorecard_params(%WorkflowBlueprint{} = blueprint, opts) do
    output_path = Keyword.get(opts, :output_path)
    runtime_params = scorecard_params(opts, output_path)

    components =
      Enum.map(blueprint.components, fn
        %ComponentBlueprint{type: type, params: params} = component
        when type in [:objective_scorecard, :verification] ->
          %{component | params: JSONMap.merge(params || %{}, runtime_params)}

        component ->
          component
      end)

    %{blueprint | components: components}
  end

  defp generated_blueprint(%Workspace{} = workspace, objective, opts) do
    model = Keyword.get(opts, :model, @default_model)
    llm_opts = llm_opts(opts)
    manifest = capability_manifest(opts)
    opts = prompt_opts(objective, opts)

    case generate_blueprint_object(
           model,
           BlueprintProposalPrompt.prompt(objective, manifest, opts),
           opts,
           llm_opts
         ) do
      {:ok, object} ->
        object
        |> validate_generated_candidate(opts, :generated)
        |> maybe_repair_generated(workspace, objective, manifest, object, opts)

      {:error, %Error{} = error} ->
        {:error,
         Error.validation("assistant coordinator could not generate a workflow blueprint",
           source: __MODULE__,
           details: %{stage: :generation, error: error}
         )}
    end
  end

  defp dynamic_blueprint(%Workspace{} = workspace, objective, opts) do
    case generated_blueprint(workspace, objective, opts) do
      {:ok, blueprint} -> {:ok, blueprint}
      {:error, %Error{} = error} -> maybe_fallback(workspace, objective, opts, error)
    end
  end

  defp maybe_repair_generated(
         {:ok, blueprint},
         _workspace,
         _objective,
         _manifest,
         _object,
         _opts
       ),
       do: {:ok, blueprint}

  defp maybe_repair_generated({:error, error}, workspace, objective, manifest, object, opts) do
    if strategy_change_repair?(opts) do
      strategy_change_repair_blueprint(workspace, objective, error, opts)
    else
      RepairLoop.repair_blueprint_object(workspace, objective, manifest, object, error, opts)
    end
  end

  defp validate_generated_candidate(object, opts, stage) do
    with {:ok, blueprint} <- WorkflowBlueprint.from_input(object),
         blueprint <- enforce_runtime_scorecard_params(blueprint, opts),
         {:ok, _report} <- BlueprintValidator.validate(blueprint, validation_opts(opts)) do
      {:ok,
       %{blueprint | metadata: JSONMap.put(blueprint.metadata || %{}, :proposal_kind, stage)}}
    else
      {:error, %Error{} = error} ->
        {:error,
         Error.validation("assistant generated workflow blueprint was rejected",
           source: __MODULE__,
           details: %{stage: stage, error: error}
         )}
    end
  end

  defp generate_blueprint_object(model, prompt, opts, llm_opts) do
    case Keyword.get(opts, :proposal_generation, @default_generation_mode) do
      :object ->
        case LLM.generate_object(model, prompt, schema(), llm_opts) do
          {:ok, object} -> {:ok, object}
          {:error, _error} -> generate_json_text_blueprint(model, prompt, llm_opts)
        end

      :json_text ->
        generate_json_text_blueprint(model, prompt, llm_opts)
    end
  end

  defp generate_json_text_blueprint(model, prompt, llm_opts) do
    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        result
        |> Result.text()
        |> decode_generated_json()

      {:retry, %Error{} = error} ->
        {:error, error}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp decode_generated_json(text) when is_binary(text) do
    text
    |> strip_markdown_fence()
    |> Jason.decode()
    |> case do
      {:ok, object} when is_map(object) ->
        {:ok, object}

      {:ok, value} ->
        {:error,
         Error.validation("generated assistant blueprint JSON must decode to an object",
           source: __MODULE__,
           details: %{value: value}
         )}

      {:error, error} ->
        {:error,
         Error.validation("generated assistant blueprint was not valid JSON",
           source: __MODULE__,
           details: %{error: Exception.message(error), text_preview: String.slice(text, 0, 4_000)}
         )}
    end
  end

  defp strip_markdown_fence(text) do
    text = String.trim(text)

    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, text, capture: :all_but_first) do
      [json] -> String.trim(json)
      _other -> text
    end
  end

  defp maybe_fallback(workspace, objective, opts, error) do
    if Keyword.get(opts, :fallback?, true) do
      with {:ok, blueprint} <- fallback_blueprint(workspace, objective, opts) do
        {:ok,
         %{
           blueprint
           | metadata:
               JSONMap.put(blueprint.metadata || %{}, :proposal_failure, %{
                 message: error.message,
                 details: error.details
               })
         }}
      end
    else
      {:error, error}
    end
  end

  defp fallback_strategy?(opts) do
    Keyword.get(opts, :proposal_strategy) in [:fallback, "fallback"] or
      Keyword.get(opts, :dynamic_blueprint?, true) in [false, "false"]
  end

  defp dynamic_strategy?(opts) do
    Keyword.get(opts, :proposal_strategy) in [
      :dynamic,
      "dynamic",
      :full_graph,
      "full_graph",
      "full-graph",
      :generated_blueprint,
      "generated_blueprint",
      "generated-blueprint"
    ]
  end

  defp routed_strategy?(opts) do
    Keyword.get(opts, :proposal_strategy) in [
      :routed,
      "routed",
      :evidence_first,
      "evidence_first",
      "evidence-first",
      :least_powerful,
      "least_powerful",
      "least-powerful"
    ] or
      Keyword.get(opts, :strategy_router?, false) in [true, "true"]
  end

  defp evidence_first_default?(opts) do
    Keyword.get(opts, :proposal_strategy) in [nil, ""] and
      Keyword.get(opts, :dynamic_blueprint?) in [nil, true, "true"]
  end

  defp routed_blueprint(%Workspace{} = workspace, objective, opts) do
    decision = route(workspace, objective, opts)

    opts =
      opts
      |> Keyword.put_new(:fallback_shape, routed_fallback_shape(decision.strategy))
      |> Keyword.put(:dynamic_blueprint?, false)

    with {:ok, blueprint} <- fallback_blueprint(workspace, objective, opts) do
      {:ok,
       %{
         blueprint
         | metadata:
             blueprint.metadata
             |> JSONMap.put(:proposal_kind, :routed_strategy)
             |> JSONMap.put(:strategy_route, StrategyRouter.metadata(decision))
       }}
    end
  end

  defp strategy_change_repair?(opts) do
    Keyword.get(opts, :strategy_change_repair?, false) in [true, "true"] or
      repair_attempts(opts) >= Keyword.get(opts, :max_same_shape_repairs, 2)
  end

  defp repair_attempts(opts) do
    case Keyword.get(opts, :repair_attempts, Keyword.get(opts, :same_shape_repair_attempts, 0)) do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> parse_non_negative_integer(value)
      _other -> 0
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> 0
    end
  end

  defp strategy_change_repair_blueprint(
         %Workspace{} = workspace,
         objective,
         %Error{} = error,
         opts
       ) do
    decision = route(workspace, objective, opts)

    opts =
      opts
      |> Keyword.put(:fallback_shape, routed_fallback_shape(decision.fallback))
      |> Keyword.put(:dynamic_blueprint?, false)

    with {:ok, blueprint} <- fallback_blueprint(workspace, objective, opts) do
      {:ok,
       %{
         blueprint
         | metadata:
             blueprint.metadata
             |> JSONMap.put(:proposal_kind, :strategy_change_repair)
             |> JSONMap.put(:strategy_route, StrategyRouter.metadata(decision))
             |> JSONMap.put(:rerouted_to, decision.fallback)
             |> JSONMap.put(:repair_failure, %{message: error.message, details: error.details})
       }}
    end
  end

  defp routed_fallback_shape(:direct_standard_agent), do: :direct_response
  defp routed_fallback_shape(:sandbox_repl), do: :direct_response
  defp routed_fallback_shape(:host_edit_workflow), do: :direct_response
  defp routed_fallback_shape(:subagent_delegation), do: :split_map_reduce_report
  defp routed_fallback_shape(:lambda_workflow), do: :split_map_reduce_report
  defp routed_fallback_shape(:generated_sandbox_component), do: :parse_normalize_report

  defp component_builder_prompt(objective, opts) do
    """
    Build and verify one sandbox-generated component for this objective.

    Objective:
    #{objective}

    Requirements:
    - Propose the component contract before writing code.
    - Write source and tests only inside the sandbox session.
    - Keep sandbox networking disabled unless the assignment review policy allows escalation.
    - Return a verified GeneratedComponent contract, source/test artifact refs, verification diagnostics, and any reviewer notes.
    - Do not materialize code into the host repository.
    #{Keyword.get(opts, :prompt_suffix, "")}
    """
    |> String.trim()
  end

  defp component_builder_budgets(%StrategyRouter{} = decision, opts) do
    decision.budgets
    |> Map.merge(%{
      max_sandbox_executions: Keyword.get(opts, :max_sandbox_executions, 6),
      max_repair_attempts: Keyword.get(opts, :max_repair_attempts, 2)
    })
    |> Map.merge(Keyword.get(opts, :budgets, %{}))
  end

  defp component_builder_output_schema do
    %{
      required: [
        "generated_component",
        "source_artifacts",
        "test_artifacts",
        "verification",
        "claims"
      ],
      claims: %{
        required: ["claim", "evidence_refs", "confidence", "reviewer_notes"]
      }
    }
  end

  defp component_builder_review_policy(opts) do
    %{
      review_gates: ["sandbox_exec", "sandbox_write_file", "generated_component_promotion"],
      network: :disabled,
      host_materialization: :requires_review
    }
    |> Map.merge(Keyword.get(opts, :review_policy, %{}))
  end

  defp component_builder_parent(%StrategyRouter{} = decision, opts) do
    cond do
      Keyword.has_key?(opts, :parent) ->
        Keyword.get(opts, :parent)

      Keyword.get(opts, :run_id) ->
        %{
          run_id: Keyword.get(opts, :run_id),
          strategy: decision.strategy,
          fallback: decision.fallback,
          depth: Keyword.get(opts, :depth, 0),
          remaining_budgets: decision.budgets
        }

      true ->
        nil
    end
  end

  defp component_builder_metadata(%StrategyRouter{} = decision, opts) do
    %{
      assignment_kind: :component_builder,
      coordinator: __MODULE__,
      strategy_route: StrategyRouter.metadata(decision),
      promotion_target: Keyword.get(opts, :promotion_target, :ephemeral),
      generated_component_policy: %{
        require_contract_first?: true,
        require_tests?: true,
        network: :disabled,
        host_materialization: :requires_review
      }
    }
    |> Map.merge(Keyword.get(opts, :metadata, %{}))
  end

  defp curated_recipe_shape(_workspace, objective, opts) do
    if Keyword.get(opts, :curated_recipes?, true) do
      sources = normalize_sources(Keyword.get(opts, :input_paths, Keyword.get(opts, :inputs, [])))
      objective_text = String.downcase(objective || "")

      cond do
        sources == [] ->
          :none

        String.contains?(objective_text, ["compare", "diff", "old", "new"]) ->
          {:ok, :compare_synthesize_report}

        Enum.any?(sources, &tabular_source?/1) and
            String.contains?(objective_text, [
              "cluster",
              "group",
              "tickets",
              "ticket",
              "csv",
              "jsonl",
              "records"
            ]) ->
          {:ok, :parse_normalize_report}

        true ->
          :none
      end
    else
      :none
    end
  end

  defp tag_curated_recipe({:ok, %WorkflowBlueprint{} = blueprint}, shape) do
    {:ok,
     %{
       blueprint
       | metadata:
           (blueprint.metadata || %{})
           |> JSONMap.put(:proposal_kind, :curated_recipe)
           |> JSONMap.put(:recipe, shape)
     }}
  end

  defp tag_curated_recipe(error, _shape), do: error

  defp llm_opts(opts) do
    opts
    |> Keyword.get(:llm_opts, [])
    |> maybe_put_client(Keyword.get(opts, :client))
  end

  defp maybe_put_client(llm_opts, nil), do: llm_opts
  defp maybe_put_client(llm_opts, client), do: Keyword.put_new(llm_opts, :client, client)

  defp validation_opts(opts) do
    [
      max_generated_function_tier: Keyword.get(opts, :max_generated_function_tier, :tier1),
      max_nodes: Keyword.get(opts, :max_nodes)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp generated_component_workflow_opts(opts) do
    opts
    |> Keyword.take([
      :id,
      :sources,
      :component_ids,
      :component_params,
      :component_policy,
      :scorecard_id,
      :scorecard_params,
      :edge_strategy,
      :stop_conditions,
      :policies,
      :metadata,
      :validate?,
      :profile,
      :toolsets,
      :disabled_tools,
      :max_generated_function_tier,
      :max_nodes,
      :sandbox_session_registry
    ])
    |> Keyword.put_new(:metadata, %{proposal_kind: :generated_component_composition})
  end

  defp generated_component_catalog_reuse?(opts) do
    Keyword.has_key?(opts, :generated_component_catalog) and
      Keyword.get(opts, :generated_component_catalog_reuse?, true) in [true, "true"]
  end

  defp generated_component_catalog_blueprint(objective, opts) do
    with {:ok, result} <- GeneratedComponentCatalog.best_match(objective, opts) do
      case result do
        nil ->
          :not_found

        result ->
          metadata =
            Map.merge(Keyword.get(opts, :metadata, %{}), %{
              proposal_kind: :generated_component_catalog_reuse,
              generated_component_catalog: %{
                selected_entry_id: result.entry.id,
                score: result.score,
                match_reasons: result.reasons
              }
            })

          workflow_opts =
            opts
            |> generated_component_workflow_opts()
            |> Keyword.put(:metadata, metadata)

          with {:ok, blueprint} <-
                 GeneratedComponentWorkflow.compose(
                   objective,
                   result.entry.component,
                   workflow_opts
                 ),
               :ok <- notify_generated_component_catalog_reuse(objective, result, blueprint, opts) do
            {:ok, blueprint}
          end
      end
    end
  end

  defp notify_generated_component_catalog_reuse(objective, result, blueprint, opts) do
    case Keyword.get(opts, :generated_component_catalog_reuse_callback) do
      nil ->
        :ok

      callback when is_function(callback, 1) ->
        event = %{
          type: :generated_component_catalog_reuse_selected,
          objective: objective,
          entry_id: result.entry.id,
          score: result.score,
          reasons: result.reasons,
          blueprint_id: blueprint.id
        }

        case callback.(event) do
          :ok ->
            :ok

          {:ok, _value} ->
            :ok

          {:error, %Error{} = error} ->
            {:error, error}

          {:error, reason} ->
            {:error,
             Error.validation("generated component catalog reuse callback failed",
               source: __MODULE__,
               details: %{reason: reason}
             )}

          other ->
            {:error,
             Error.validation(
               "generated component catalog reuse callback returned invalid result",
               source: __MODULE__,
               details: %{result: other}
             )}
        end

      callback ->
        {:error,
         Error.validation("generated component catalog reuse callback must be a unary function",
           source: __MODULE__,
           details: %{callback: inspect(callback)}
         )}
    end
  end

  defp continue_without_catalog_reuse(workspace, objective, opts) do
    opts = Keyword.put(opts, :generated_component_catalog_reuse?, false)

    cond do
      dynamic_strategy?(opts) ->
        dynamic_blueprint(workspace, objective, opts)

      fallback_strategy?(opts) ->
        fallback_blueprint(workspace, objective, opts)

      routed_strategy?(opts) ->
        routed_blueprint(workspace, objective, opts)

      match?({:ok, _shape}, curated_recipe_shape(workspace, objective, opts)) ->
        {:ok, shape} = curated_recipe_shape(workspace, objective, opts)

        workspace
        |> fallback_blueprint(objective, Keyword.put(opts, :fallback_shape, shape))
        |> tag_curated_recipe(shape)

      evidence_first_default?(opts) ->
        routed_blueprint(workspace, objective, opts)

      true ->
        dynamic_blueprint(workspace, objective, opts)
    end
  end

  defp generated_component_promotion_flow_opts(opts, objective, generated_component_proposal) do
    workflow_opts =
      generated_component_workflow_opts(opts)
      |> Keyword.merge(Keyword.get(opts, :workflow_opts, []), fn
        :metadata, left, right when is_map(left) and is_map(right) -> Map.merge(left, right)
        _key, _left, right -> right
      end)
      |> Keyword.update(
        :metadata,
        %{proposal_kind: :generated_component_promotion_flow},
        fn metadata ->
          Map.merge(metadata, %{proposal_kind: :generated_component_promotion_flow})
        end
      )

    opts
    |> Keyword.take([
      :id,
      :source_files,
      :test_files,
      :test_command,
      :test_runtime,
      :proof_opts,
      :sandbox,
      :sandbox_spec,
      :sandbox_cwd,
      :session_opts,
      :attach_opts,
      :close_opts,
      :profile,
      :server,
      :open_session,
      :attach,
      :close_attach,
      :close_session,
      :promotion_target,
      :review_decision,
      :resume_key,
      :timeout_ms,
      :max_output_bytes,
      :network,
      :capability_gap,
      :generated_component_catalog
    ])
    |> maybe_put_generated_component_gap(objective, generated_component_proposal, opts)
    |> Keyword.put(:workflow_objective, objective)
    |> Keyword.put(:workflow_opts, workflow_opts)
  end

  defp prompt_opts(objective, opts) do
    case GeneratedComponentCatalog.prompt_context(objective, opts) do
      {:ok, context} ->
        Keyword.put(opts, :generated_component_catalog_context, context)

      {:error, %Error{} = error} ->
        Keyword.put(opts, :generated_component_catalog_error, %{
          message: error.message,
          details: error.details
        })
    end
  end

  defp maybe_put_generated_component_gap(flow_opts, objective, proposal, opts) do
    cond do
      Keyword.has_key?(opts, :capability_gap) ->
        flow_opts

      Keyword.has_key?(opts, :generated_component_catalog) ->
        case GeneratedComponentCatalog.gap_for_proposal(objective, proposal, opts) do
          {:ok, gap} -> Keyword.put(flow_opts, :capability_gap, gap)
          {:error, _error} -> flow_opts
        end

      true ->
        flow_opts
    end
  end

  defp promotion_flow_blueprint({:ok, %{workflow: %WorkflowBlueprint{} = blueprint}}),
    do: {:ok, blueprint}

  defp promotion_flow_blueprint({:ok, result}) do
    {:error,
     Error.validation("generated component promotion flow did not produce a workflow",
       source: __MODULE__,
       details: %{
         status: result.status,
         component_id: result.component.id,
         promotion_decision: result.promotion_decision,
         repair_context: result.repair_context
       }
     )}
  end

  defp promotion_flow_blueprint({:error, %Error{} = error}), do: {:error, error}

  defp normalize_sources([]), do: []

  defp normalize_sources(paths) when is_list(paths) do
    paths
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%{path: _path} = source, _index} -> source
      {path, index} when is_binary(path) -> %{id: "source_#{index}", path: path}
      {source, index} -> %{id: "source_#{index}", path: to_string(source)}
    end)
  end

  defp normalize_sources(path) when is_binary(path), do: [%{id: "source_1", path: path}]
  defp normalize_sources(_other), do: []

  defp fallback_graph(:compare_synthesize_report, sources, opts) do
    components = [
      ComponentBlueprint.new!("discover_sources", :source_discovery,
        params: source_discovery_params(sources, opts)
      ),
      ComponentBlueprint.new!("compare_documents", :document_compare),
      ComponentBlueprint.new!("compose_report", :report_composer,
        params: report_composer_params(opts, "Comparison Report")
      )
    ]

    edges = [
      %{from: "discover_sources", to: "compare_documents"},
      %{from: "compare_documents", to: "compose_report"}
    ]

    {components, edges, "compose_report"}
  end

  defp fallback_graph(:parse_normalize_report, sources, opts) do
    components = [
      ComponentBlueprint.new!("discover_sources", :source_discovery,
        params: source_discovery_params(sources, opts)
      ),
      ComponentBlueprint.new!("parse_records", :tabular_parser),
      ComponentBlueprint.new!("group_records", :record_group,
        params: %{
          group_by: Keyword.get(opts, :group_by),
          dedupe_by: Keyword.get(opts, :dedupe_by, [])
        }
      ),
      ComponentBlueprint.new!("compose_report", :report_composer,
        params: report_composer_params(opts, "Record Report")
      )
    ]

    edges = [
      %{from: "discover_sources", to: "parse_records"},
      %{from: "parse_records", to: "group_records"},
      %{from: "group_records", to: "compose_report"}
    ]

    {components, edges, "compose_report"}
  end

  defp fallback_graph(:direct_response, _sources, opts) do
    components = [
      ComponentBlueprint.new!("synthesize_response", :llm_leaf,
        params:
          %{
            strategy: :llm_reduce,
            group_prompt: direct_response_group_prompt(),
            prompt: direct_response_prompt(),
            max_group_items: 1
          }
          |> maybe_put_model(opts)
      )
    ]

    {components, [], "synthesize_response"}
  end

  defp fallback_graph(_shape, sources, opts) do
    components = [
      ComponentBlueprint.new!("discover_sources", :source_discovery,
        params: source_discovery_params(sources, opts)
      ),
      ComponentBlueprint.new!("split_sources", :source_splitter,
        params: %{
          strategy: Keyword.get(opts, :split_strategy, :paragraph),
          max_bytes: Keyword.get(opts, :max_slice_bytes, @default_split_bytes)
        }
      ),
      ComponentBlueprint.new!("materialize_slices", :source_materializer,
        params: %{
          max_slice_bytes: Keyword.get(opts, :max_slice_bytes, @default_split_bytes),
          max_total_bytes: Keyword.get(opts, :max_total_source_bytes, 160_000)
        }
      ),
      ComponentBlueprint.new!("extract_slice_notes", :llm_map,
        params:
          %{
            prompt: map_prompt(),
            limit: Keyword.get(opts, :max_llm_map_calls, 80),
            max_concurrency: Keyword.get(opts, :max_llm_map_concurrency, 4)
          }
          |> maybe_put_model(opts)
      ),
      ComponentBlueprint.new!("join_slice_notes", :blueprint_reduce, params: %{strategy: :join}),
      ComponentBlueprint.new!("synthesize_report", :llm_leaf,
        params:
          %{
            strategy: :llm_reduce,
            group_prompt: group_prompt(),
            prompt: final_prompt(),
            max_group_items: Keyword.get(opts, :max_reduce_group_items, 12)
          }
          |> maybe_put_model(opts)
      )
    ]

    edges = [
      %{from: "discover_sources", to: "split_sources"},
      %{from: "split_sources", to: "materialize_slices"},
      %{from: "materialize_slices", to: "extract_slice_notes"},
      %{from: "extract_slice_notes", to: "join_slice_notes"},
      %{from: "join_slice_notes", to: "synthesize_report"}
    ]

    {components, edges, "synthesize_report"}
  end

  defp maybe_append_writer(components, nil, _write_policy, _terminal_node), do: components
  defp maybe_append_writer(components, "", _write_policy, _terminal_node), do: components

  defp maybe_append_writer(components, output_path, write_policy, _terminal_node) do
    components ++
      [
        ComponentBlueprint.new!("write_artifact", :artifact_writer,
          params: %{path: output_path, write_policy: write_policy}
        )
      ]
  end

  defp append_verification(components, scorecard_params) do
    components ++
      [
        ComponentBlueprint.new!("verify_objective", :objective_scorecard,
          params: scorecard_params
        )
      ]
  end

  defp maybe_append_writer_edges(edges, nil, _terminal_node), do: edges
  defp maybe_append_writer_edges(edges, "", _terminal_node), do: edges

  defp maybe_append_writer_edges(edges, _output_path, terminal_node) do
    edges ++ [%{from: terminal_node, to: "write_artifact"}]
  end

  defp append_verification_edges(edges, nil, terminal_node),
    do: edges ++ [%{from: terminal_node, to: "verify_objective"}]

  defp append_verification_edges(edges, "", terminal_node),
    do: edges ++ [%{from: terminal_node, to: "verify_objective"}]

  defp append_verification_edges(edges, _output_path, _terminal_node) do
    edges ++ [%{from: "write_artifact", to: "verify_objective"}]
  end

  defp fallback_shape(workspace, objective, sources, opts) do
    case Keyword.get(opts, :fallback_shape) do
      value
      when value in [
             :split_map_reduce_report,
             :parse_normalize_report,
             :compare_synthesize_report
           ] ->
        value

      value when value in [:direct_response, :direct_answer] ->
        :direct_response

      value
      when value in ["direct_response", "direct-response", "direct_answer", "direct-answer"] ->
        :direct_response

      value when value in ["split_map_reduce_report", "split-map-reduce-report"] ->
        :split_map_reduce_report

      value when value in ["parse_normalize_report", "parse-normalize-report"] ->
        :parse_normalize_report

      value when value in ["compare_synthesize_report", "compare-synthesize-report"] ->
        :compare_synthesize_report

      _other ->
        inferred_fallback_shape(workspace, objective, sources)
    end
  end

  defp inferred_fallback_shape(workspace, objective, sources) do
    objective = String.downcase(objective || "")

    cond do
      sources == [] ->
        :direct_response

      String.contains?(objective, ["compare", "diff", "old", "new"]) or length(sources) >= 2 ->
        :compare_synthesize_report

      Enum.any?(sources, &tabular_source?/1) or
          String.contains?(objective, ["csv", "jsonl", "cluster", "cleanup", "tickets"]) ->
        :parse_normalize_report

      Enum.any?(sources, &directory_source?(workspace, &1)) ->
        :split_map_reduce_report

      true ->
        :split_map_reduce_report
    end
  end

  defp maybe_put_recipe_defaults(:parse_normalize_report, objective, opts) do
    objective = String.downcase(objective || "")

    opts =
      if Keyword.get(opts, :group_by) in [nil, ""] and
           String.contains?(objective, ["ticket", "tickets", "cluster", "group"]) do
        Keyword.put(opts, :group_by, "theme")
      else
        opts
      end

    if Keyword.get(opts, :dedupe_by) in [nil, []] and
         String.contains?(objective, ["ticket", "tickets"]) do
      Keyword.put(opts, :dedupe_by, ["ticket_id", "ticket", "id"])
    else
      opts
    end
  end

  defp maybe_put_recipe_defaults(_shape, _objective, opts), do: opts

  defp tabular_source?(%{path: path}) when is_binary(path), do: tabular_path?(path)
  defp tabular_source?(%{"path" => path}) when is_binary(path), do: tabular_path?(path)
  defp tabular_source?(path) when is_binary(path), do: tabular_path?(path)
  defp tabular_source?(_source), do: false

  defp tabular_path?(path) do
    extension = path |> Path.extname() |> String.downcase()
    extension in [".csv", ".jsonl", ".json"]
  end

  defp direct_response_group_prompt do
    """
    Objective:
    {{objective}}

    Request context:
    {{items}}

    Extract the user's direct request. If no external source material is present,
    keep only the objective and any explicit constraints.
    """
  end

  defp direct_response_prompt do
    """
    Objective:
    {{objective}}

    Direct request context:
    {{items}}

    Produce the requested assistant response directly. Do not claim external
    source evidence unless it appears in the request context.
    """
  end

  defp directory_source?(workspace, %{path: path}) when is_binary(path),
    do: directory_path?(workspace, path)

  defp directory_source?(workspace, %{"path" => path}) when is_binary(path),
    do: directory_path?(workspace, path)

  defp directory_source?(workspace, path) when is_binary(path),
    do: directory_path?(workspace, path)

  defp directory_source?(_workspace, _source), do: false

  defp directory_path?(workspace, path) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read) do
      File.dir?(resolved.path)
    else
      _other -> false
    end
  end

  defp stop_conditions(nil),
    do: ["final assistant output produced", "objective scorecard checked"]

  defp stop_conditions(""), do: stop_conditions(nil)

  defp stop_conditions(_output_path) do
    ["artifact written", "objective scorecard checked"]
  end

  defp report_composer_params(opts, default_title) do
    %{
      title: Keyword.get(opts, :report_title, default_title),
      sections: Keyword.get(opts, :required_sections, [])
    }
  end

  defp source_discovery_params(sources, opts) do
    %{
      paths: Enum.map(sources, & &1.path),
      max_depth: Keyword.get(opts, :source_discovery_max_depth, 3),
      max_files: Keyword.get(opts, :source_discovery_max_files, 96)
    }
  end

  defp scorecard_params(opts, output_path) do
    %{
      artifact_path: output_path,
      required_sections: Keyword.get(opts, :required_sections, []),
      required_source_cues:
        Keyword.get(opts, :required_source_cues, Keyword.get(opts, :source_cues, [])),
      require_provenance?: Keyword.get(opts, :require_provenance?, false),
      require_artifact_quality?: Keyword.get(opts, :require_artifact_quality?, false),
      comparison_required?: Keyword.get(opts, :comparison_required?, false)
    }
  end

  defp allowed_paths(:docs_only), do: [".docs/**"]
  defp allowed_paths("docs_only"), do: [".docs/**"]
  defp allowed_paths("docs-only"), do: [".docs/**"]
  defp allowed_paths(:none), do: []
  defp allowed_paths(_policy), do: ["."]

  defp maybe_put_model(params, opts) do
    case Keyword.get(opts, :model) do
      nil -> params
      model -> Map.put(params, :model, model)
    end
  end

  defp map_prompt do
    """
    Objective:
    {{objective}}

    Source: {{source_path}} slice {{index}} lines {{start_line}}-{{end_line}}
    {{text}}

    Produce concise structured notes for this slice that are useful for the objective.
    Include concrete events, actors, entities, decisions, claims, evidence, uncertainties, and source line references when present.
    Do not invent facts beyond this slice.
    """
  end

  defp group_prompt do
    """
    Objective:
    {{objective}}

    Slice notes group {{group_index}} of {{group_count}}:
    {{items}}

    Merge these notes into a compact evidence-preserving digest. Deduplicate repeated entities and events, keep provenance hints, and keep uncertainties explicit.
    """
  end

  defp final_prompt do
    """
    Objective:
    {{objective}}

    Merged notes:
    {{items}}

    Write the requested durable report. Use clear markdown sections derived from the objective, preserve important provenance hints, and include residual uncertainty when evidence is thin.
    The merged notes are evidence produced by local source components. If they include local paths or source provenance, do not claim you could not inspect those declared paths.
    If the objective says to wait for approval before writing, treat that as a runtime control already handled by RunicAI review. Do not ask the user for approval in the artifact content. Produce the artifact body that should be reviewed and written after approval.
    """
  end
end
