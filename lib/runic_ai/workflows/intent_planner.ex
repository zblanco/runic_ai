defmodule RunicAI.Workflows.IntentPlanner do
  @moduledoc """
  Product boundary from a user intent to a routed workflow planning result.

  Fresh drafts reuse the existing assistant coordinator only as an authoring
  adapter. The accepted product truth is canonical workflow IR, which is
  validated, compiled, and persisted as an immutable draft revision with the
  routing decision and catalog snapshot pinned in provenance.
  """

  alias RunicAI.Assistant.RLM.Coordinator, as: AssistantCoordinator
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.Coordinator, as: CodingCoordinator
  alias RunicAI.Coding.Workspace
  alias RunicAI.JSONMap
  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Workflows.Adapters.AssistantBlueprint
  alias RunicAI.Workflows.Adapters.CodingProposal
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IntentRouter
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.OperationProtocol
  alias RunicAI.Workflows.Repair

  @coordinator_opts [
    :blueprint,
    :client,
    :llm_opts,
    :model,
    :proposal_strategy,
    :proposal_generation,
    :fallback?,
    :temperature,
    :max_completion_tokens,
    :receive_timeout,
    :write_policy,
    :require_artifact_quality?,
    :required_source_cues,
    :source_cues,
    :conversation_context,
    :conversation_history,
    :capability_profile
  ]

  @spec plan(Store.t(), Workspace.t(), map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def plan(%Store{} = store, %Workspace{} = workspace, request, opts \\ [])
      when is_list(opts) do
    router_opts =
      Keyword.take(opts, [:strategy, :limit, :exact_similarity, :adapt_similarity])

    with {:ok, route} <- IntentRouter.route(store, request, router_opts) do
      realize_route(store, workspace, route, opts)
    end
  end

  defp realize_route(_store, _workspace, %{strategy: :direct} = route, _opts) do
    {:ok, %{status: :ready, strategy: :direct, route: route}}
  end

  defp realize_route(_store, _workspace, %{strategy: :reuse_exact} = route, _opts) do
    {:ok,
     %{
       status: :ready,
       strategy: :reuse_exact,
       route: route,
       reference: route.selected.reference,
       contract: route.selected.contract
     }}
  end

  defp realize_route(store, workspace, %{strategy: :adapt} = route, opts) do
    request = route.request
    catalog_hash = Catalog.snapshot_hash()

    with {:ok, source_ir} <- IR.from_input(route.selected.revision.ir_json),
         {:ok, base_ir} <- fork_adaptation(source_ir, route, request, opts, catalog_hash),
         {:ok, edited, operations, authoring} <-
           adapt_and_apply(source_ir, base_ir, request, opts),
         authored_ir = pin_execution_model(edited.ir, opts),
         {:ok, repaired} <-
           Repair.to_runnable(authored_ir, workspace, repair_opts(opts, request.objective)),
         ir = pin_execution_model(repaired.ir, opts),
         {:ok, compiled} <- Compiler.compile(ir, workspace, compile_opts(opts)),
         {:ok, created} <-
           WorkflowDefinitions.create_draft(store,
             workflow_key: adaptation_workflow_key(route, request, opts),
             workflow_name: Keyword.get(opts, :workflow_name, request.objective),
             scope_type: Keyword.get(opts, :scope_type, :local),
             scope_id: Keyword.get(opts, :scope_id),
             ir: ir,
             actor: Keyword.get(opts, :actor, "planner:agent"),
             catalog_hash: catalog_hash,
             metadata: %{created_from: "intent_planner_adaptation"},
             revision_metadata:
               adaptation_revision_metadata(
                 route,
                 request,
                 edited,
                 authoring,
                 repaired.history,
                 opts
               )
           ),
         {:ok, artifact} <-
           WorkflowDefinitions.record_compilation(store, created.revision.id, %{
             artifact: compiled,
             compiled_hash: compiled.compiled_hash,
             catalog_hash: catalog_hash,
             source_map: compiled.source_map,
             metadata: %{
               artifact_format: "recompile_from_ir_v1",
               compiled_hash_format: "stable_lowering_v2",
               catalog_compatibility: "strict_current_v1",
               compiled_by: "intent_planner_adaptation"
             }
           }),
         {:ok, projection} <-
           WorkflowDefinitions.regenerate_json_projection(store, created.revision.id) do
      {:ok,
       %{
         status: :drafted,
         strategy: :adapt,
         route: route,
         base_reference: route.selected.reference,
         contract: route.selected.contract,
         adaptation_operations: operations,
         adaptation_authoring: authoring,
         repair_history: repaired.history,
         edit: edited,
         ir: ir,
         compiled: compiled,
         definition: created,
         artifact: artifact,
         projection: projection
       }}
    end
  end

  defp realize_route(store, workspace, %{strategy: :draft} = route, opts) do
    request = route.request
    catalog_hash = Catalog.snapshot_hash()

    with {:ok, authored} <- author_draft(workspace, request, opts),
         adapted = authored.adapter,
         authored_ir =
           adapted.ir
           |> attach_planning_provenance(route, catalog_hash)
           |> pin_execution_model(opts),
         {:ok, repaired} <-
           Repair.to_runnable(authored_ir, workspace, repair_opts(opts, request.objective)),
         ir =
           repaired.ir
           |> pin_execution_model(opts)
           |> then(&%{&1 | revision: authored_ir.revision}),
         {:ok, compiled} <- Compiler.compile(ir, workspace, compile_opts(opts)),
         {:ok, created} <-
           WorkflowDefinitions.create_draft(store,
             workflow_key: workflow_key(ir, opts),
             workflow_name: Keyword.get(opts, :workflow_name, request.objective),
             scope_type: Keyword.get(opts, :scope_type, :local),
             scope_id: Keyword.get(opts, :scope_id),
             ir: ir,
             actor: Keyword.get(opts, :actor, "planner:agent"),
             catalog_hash: catalog_hash,
             metadata: %{created_from: "intent_planner"},
             revision_metadata:
               revision_metadata(route, request, authored, repaired.history, opts)
           ),
         {:ok, artifact} <-
           WorkflowDefinitions.record_compilation(store, created.revision.id, %{
             artifact: compiled,
             compiled_hash: compiled.compiled_hash,
             catalog_hash: catalog_hash,
             source_map: compiled.source_map,
             metadata: %{
               artifact_format: "recompile_from_ir_v1",
               compiled_hash_format: "stable_lowering_v2",
               catalog_compatibility: "strict_current_v1",
               compiled_by: "intent_planner"
             }
           }),
         {:ok, projection} <-
           WorkflowDefinitions.regenerate_json_projection(store, created.revision.id) do
      result = %{
        status: :drafted,
        strategy: :draft,
        route: route,
        adapter_diagnostics: adapted.diagnostics,
        repair_history: repaired.history,
        ir: ir,
        compiled: compiled,
        definition: created,
        artifact: artifact,
        projection: projection
      }

      {:ok, Map.put(result, authored.result_key, authored.source)}
    end
  end

  defp author_draft(workspace, request, opts) do
    case draft_dialect(request, opts) do
      :component -> author_component_draft(workspace, request, opts)
      :coding -> author_coding_draft(workspace, request, opts)
      dialect -> invalid_draft_dialect(dialect)
    end
  end

  defp author_component_draft(workspace, request, opts) do
    coordinator_opts =
      opts
      |> Keyword.take(@coordinator_opts)
      |> Keyword.put(:proposal_strategy, :generated_blueprint)
      |> Keyword.put(:input_paths, request.input_paths)
      |> Keyword.put(:output_path, request.output_path)
      |> Keyword.put(:required_sections, request.required_sections)

    with {:ok, blueprint} <-
           AssistantCoordinator.propose(workspace, request.objective, coordinator_opts),
         {:ok, adapted} <- AssistantBlueprint.adapt(blueprint) do
      {:ok,
       %{
         adapter: adapted,
         adapter_source: "assistant_workflow_blueprint",
         result_key: :blueprint,
         source: blueprint
       }}
    end
  end

  defp author_coding_draft(workspace, request, opts) do
    with {:ok, environment} <- CodebaseEnvironment.new(workspace, index?: true),
         {:ok, proposal, report} <-
           CodingCoordinator.propose(
             request.objective,
             environment,
             coding_coordinator_opts(opts)
           ),
         {:ok, adapted} <- CodingProposal.adapt(proposal) do
      {:ok,
       %{
         adapter: adapted,
         adapter_source: "coding_workflow_proposal",
         result_key: :proposal,
         source: proposal,
         domain_validation_report: report
       }}
    end
  end

  defp draft_dialect(request, opts) do
    opts
    |> Keyword.get_lazy(:dialect, fn -> metadata_value(request.metadata, :dialect, :component) end)
    |> case do
      "component" -> :component
      "coding" -> :coding
      dialect -> dialect
    end
  end

  defp invalid_draft_dialect(dialect) do
    {:error,
     RunicAI.Error.validation("unknown workflow intent draft dialect",
       source: __MODULE__,
       details: %{code: :invalid_workflow_draft_dialect, dialect: dialect}
     )}
  end

  defp coding_coordinator_opts(opts) do
    opts
    |> Keyword.get(:coding_opts, [])
    |> maybe_put(:proposal, Keyword.get(opts, :coding_proposal))
    |> maybe_put(:model, Keyword.get(opts, :model))
    |> maybe_put(:client, Keyword.get(opts, :client))
    |> maybe_put(:llm_opts, Keyword.get(opts, :llm_opts))
    |> maybe_put(:proposal_llm_timeout_ms, Keyword.get(opts, :receive_timeout))
  end

  defp attach_planning_provenance(%IR{} = ir, route, catalog_hash) do
    planning = %{
      strategy: route.strategy,
      rationale: route.rationale,
      reasons: route.reasons,
      catalog_hash: catalog_hash,
      considered_candidates: candidate_summaries(route.candidates)
    }

    %{ir | metadata: Map.put(ir.metadata || %{}, :planning, planning)}
  end

  defp pin_execution_model(%IR{} = ir, opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" ->
        nodes =
          Map.new(ir.nodes, fn {id, node} ->
            node =
              if Enum.any?(node.effects, &(to_string(&1) == "model_call")) do
                %{node | arguments: JSONMap.put(node.arguments, :model, model)}
              else
                node
              end

            {id, node}
          end)

        %{ir | nodes: nodes}

      _other ->
        ir
    end
  end

  defp revision_metadata(route, request, authored, repair_history, opts) do
    adapted = authored.adapter

    %{
      planning: %{
        strategy: route.strategy,
        rationale: route.rationale,
        reasons: route.reasons,
        considered_candidates: candidate_summaries(route.candidates),
        request: request,
        request_metadata: request.metadata
      },
      adapter: %{
        source: authored.adapter_source,
        lossless: adapted.lossless?,
        diagnostics: adapted.diagnostics
      },
      repair: %{
        strategy: "typed_operations",
        attempts: length(repair_history),
        history: repair_history
      },
      public_contract:
        Keyword.get_lazy(opts, :public_contract, fn -> intent_contract(request) end)
    }
  end

  defp adaptation_revision_metadata(route, request, edited, authoring, repair_history, opts) do
    %{
      planning: %{
        strategy: :adapt,
        rationale: route.rationale,
        reasons: route.reasons,
        considered_candidates: candidate_summaries(route.candidates),
        selected_base: route.selected.reference,
        request: request,
        request_metadata: request.metadata
      },
      adaptation: %{
        protocol: "typed_operations_v1",
        authoring: authoring,
        base_reference: route.selected.reference,
        base_hash: edited.base_hash,
        result_hash: edited.result_hash,
        operations: edited.operations,
        affected_nodes: edited.affected_nodes,
        diff: edited.diff
      },
      repair: %{
        strategy: "typed_operations",
        attempts: length(repair_history),
        history: repair_history
      },
      public_contract:
        Keyword.get_lazy(opts, :public_contract, fn -> intent_contract(request) end)
    }
  end

  defp adaptation_operations(source_ir, request, opts) do
    case Keyword.fetch(opts, :adapt_operations) do
      {:ok, operations} when is_list(operations) ->
        {:ok, operations, %{source: "provided", provider_usage: %{}}}

      {:ok, other} ->
        {:error,
         RunicAI.Error.validation("workflow adaptation operations must be a list",
           source: __MODULE__,
           details: %{code: :invalid_adaptation_operations, operations: other}
         )}

      :error ->
        prompt = adaptation_prompt(source_ir, request)

        with {:ok, %Result{} = result} <-
               LLM.generate_text(
                 Keyword.get(opts, :model, "openai:gpt-5.6-luna"),
                 prompt,
                 adaptation_llm_opts(opts)
               ) do
          response = Result.text(result)

          case decode_adaptation_operations(response) do
            {:ok, operations} ->
              {:ok, operations,
               %{
                 source: "model",
                 model: Keyword.get(opts, :model, "openai:gpt-5.6-luna"),
                 provider_usage: result.usage,
                 prompt: prompt,
                 response: response
               }}

            {:error, error} ->
              repair_malformed_adaptation(
                source_ir,
                request,
                prompt,
                response,
                result,
                error,
                opts
              )
          end
        end
    end
  end

  defp repair_malformed_adaptation(
         source_ir,
         request,
         original_prompt,
         response,
         result,
         error,
         opts
       ) do
    repair_prompt = adaptation_decode_repair_prompt(source_ir, request, response, error)

    with {:ok, %Result{} = repair_result} <-
           LLM.generate_text(
             Keyword.get(opts, :model, "openai:gpt-5.6-luna"),
             repair_prompt,
             adaptation_llm_opts(opts)
           ),
         repaired_response = Result.text(repair_result),
         {:ok, operations} <- decode_adaptation_operations(repaired_response) do
      {:ok, operations,
       %{
         source: "model",
         model: Keyword.get(opts, :model, "openai:gpt-5.6-luna"),
         provider_usage: result.usage,
         prompt: original_prompt,
         response: response,
         repair: %{
           attempted: true,
           stage: "decode",
           error: inspect(error),
           prompt: repair_prompt,
           response: repaired_response,
           provider_usage: repair_result.usage
         }
       }}
    end
  end

  defp adapt_and_apply(source_ir, base_ir, request, opts) do
    with {:ok, operations, authoring} <- adaptation_operations(source_ir, request, opts) do
      case Editor.apply(base_ir, OperationProtocol.batch(base_ir, operations)) do
        {:ok, edited} ->
          {:ok, edited, operations, authoring}

        {:error, error} ->
          repair_and_apply_adaptation(
            source_ir,
            base_ir,
            request,
            operations,
            authoring,
            error,
            opts
          )
      end
    end
  end

  defp repair_and_apply_adaptation(
         source_ir,
         base_ir,
         request,
         operations,
         %{source: "model"} = authoring,
         error,
         opts
       ) do
    prompt = adaptation_repair_prompt(source_ir, request, operations, error)

    with {:ok, %Result{} = result} <-
           LLM.generate_text(
             Keyword.get(opts, :model, "openai:gpt-5.6-luna"),
             prompt,
             adaptation_llm_opts(opts)
           ),
         response = Result.text(result),
         {:ok, repaired_operations} <- decode_adaptation_operations(response),
         {:ok, edited} <-
           Editor.apply(base_ir, OperationProtocol.batch(base_ir, repaired_operations)) do
      {:ok, edited, repaired_operations,
       Map.put(authoring, :repair, %{
         attempted: true,
         error: inspect(error),
         prompt: prompt,
         response: response,
         provider_usage: result.usage
       })}
    end
  end

  defp repair_and_apply_adaptation(
         _source_ir,
         _base_ir,
         _request,
         _operations,
         _authoring,
         error,
         _opts
       ),
       do: {:error, error}

  defp adaptation_prompt(source_ir, request) do
    """
    Adapt this proven RunicAI workflow to the new request using the smallest
    targeted semantic operation transaction. Preserve compatible topology and
    acceptance. Bind declared sources, output paths, required sections, and
    safe policies where the existing component arguments support them. Do not
    regenerate the complete workflow.

    New request: #{Jason.encode!(request)}

    #{OperationProtocol.grammar()}

    Current editable manifest:
    #{Jason.encode!(OperationProtocol.editable_manifest(source_ir))}
    """
  end

  defp adaptation_repair_prompt(source_ir, request, operations, error) do
    """
    The proposed typed workflow adaptation transaction failed deterministic
    validation. Return one corrected complete operation transaction. Preserve
    valid local edits, remove unnecessary edits, and do not regenerate the
    workflow.

    New request: #{Jason.encode!(request)}
    Failed operations: #{Jason.encode!(operations)}
    Validation failure: #{inspect(error)}

    #{OperationProtocol.grammar()}

    Current editable manifest:
    #{Jason.encode!(OperationProtocol.editable_manifest(source_ir))}
    """
  end

  defp adaptation_decode_repair_prompt(source_ir, request, response, error) do
    """
    The proposed typed workflow adaptation was not valid protocol JSON. Return
    one corrected complete operation transaction. Preserve the intended local
    edits, remove unnecessary edits, and do not regenerate the workflow.

    New request: #{Jason.encode!(request)}
    Invalid response: #{response}
    Decode failure: #{inspect(error)}

    #{OperationProtocol.grammar()}

    Current editable manifest:
    #{Jason.encode!(OperationProtocol.editable_manifest(source_ir))}
    """
  end

  defp decode_adaptation_operations(response) do
    text = String.trim(response)

    text =
      case Regex.run(~r/\A```(?:json)?\s*\n?(.*?)\n?```\z/su, text) do
        [_, inner] -> String.trim(inner)
        _other -> text
      end

    with {:ok, decoded} <- Jason.decode(text),
         operations when is_list(operations) <- Map.get(decoded, "operations") do
      {:ok, operations}
    else
      {:error, error} ->
        {:error,
         RunicAI.Error.validation("workflow adaptation response was not valid JSON",
           source: __MODULE__,
           details: %{code: :invalid_adaptation_json, error: Exception.message(error)}
         )}

      _other ->
        {:error,
         RunicAI.Error.validation("workflow adaptation response must contain operations",
           source: __MODULE__,
           details: %{code: :invalid_adaptation_operations}
         )}
    end
  end

  defp fork_adaptation(source_ir, route, request, opts, catalog_hash) do
    key = adaptation_workflow_key(route, request, opts)

    planning = %{
      strategy: :adapt,
      rationale: route.rationale,
      reasons: route.reasons,
      catalog_hash: catalog_hash,
      selected_base: route.selected.reference,
      considered_candidates: candidate_summaries(route.candidates)
    }

    IR.new("workflow:#{key}", request.objective,
      revision: 1,
      inputs: source_ir.inputs,
      nodes: source_ir.nodes,
      edges: source_ir.edges,
      acceptance: source_ir.acceptance,
      policies: source_ir.policies,
      holes: source_ir.holes,
      presentation: source_ir.presentation,
      metadata: JSONMap.put(source_ir.metadata || %{}, :planning, planning)
    )
  end

  defp adaptation_workflow_key(route, request, opts) do
    Keyword.get(opts, :workflow_key) ||
      "#{route.selected.workflow.workflow_key}-adapt-#{short_hash(request)}"
  end

  defp short_hash(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
  end

  defp adaptation_llm_opts(opts) do
    opts
    |> Keyword.get(:llm_opts, [])
    |> maybe_put(:client, Keyword.get(opts, :client))
    |> maybe_put(:receive_timeout, Keyword.get(opts, :receive_timeout))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp metadata_value(metadata, key, default) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))
  end

  defp intent_contract(request) do
    %{
      inputs: %{
        type: "object",
        required: ["objective", "input", "input_paths", "output_path", "required_sections"],
        properties: %{
          "objective" => %{type: "string", const: request.objective},
          "input" => %{type: "object", const: request.input},
          "input_paths" => %{type: "array", const: request.input_paths},
          "output_path" => %{const: request.output_path},
          "required_sections" => %{type: "array", const: request.required_sections}
        }
      },
      adaptation_inputs: %{
        type: "object",
        required: ["objective", "input", "input_paths", "output_path", "required_sections"],
        properties: %{
          "objective" => %{type: "string"},
          "input" => %{type: "object"},
          "input_paths" => %{type: "array", items: %{type: "string"}},
          "output_path" => %{type: "any"},
          "required_sections" => %{type: "array", items: %{type: "string"}}
        }
      },
      outputs: %{type: "any"},
      metadata: %{derived_from: "workflow_intent_v1"}
    }
  end

  defp candidate_summaries(candidates) do
    Enum.map(candidates, fn candidate ->
      %{
        workflow_key: candidate.workflow.workflow_key,
        revision: candidate.revision.revision,
        definition_hash: candidate.revision.semantic_hash,
        contract_hash: candidate.contract.contract_hash,
        compatible: candidate.compatible?,
        adaptable: candidate.adaptable?,
        objective_similarity: candidate.objective_similarity,
        reasons: Enum.map(candidate.reasons, &candidate_reason/1)
      }
    end)
  end

  defp candidate_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp candidate_reason({code, value}) when is_atom(code) do
    %{code: Atom.to_string(code), value: value}
  end

  defp candidate_reason(reason), do: inspect(reason)

  defp workflow_key(ir, opts) do
    Keyword.get(opts, :workflow_key) ||
      ir.id
      |> String.replace_prefix("workflow:", "")
      |> String.replace_prefix("assistant:", "")
      |> String.replace(~r/[^a-zA-Z0-9_-]+/u, "-")
      |> String.trim("-")
  end

  defp compile_opts(opts), do: Keyword.get(opts, :compile_opts, [])

  defp repair_opts(opts, objective) do
    opts
    |> Keyword.take([
      :model,
      :client,
      :llm_opts,
      :receive_timeout,
      :workflow_repair_attempts,
      :compile_opts
    ])
    |> Keyword.put(:objective, objective)
  end
end
