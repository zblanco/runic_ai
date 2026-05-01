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
  alias RunicAI.LLM
  alias RunicAI.LLM.Result

  @default_split_bytes 8_000
  @default_model "openai:gpt-5.4-mini"
  @default_generation_mode :json_text

  @spec propose(Workspace.t(), String.t(), keyword()) ::
          {:ok, WorkflowBlueprint.t()} | {:error, Error.t()}
  def propose(%Workspace{} = workspace, objective, opts \\ [])
      when is_binary(objective) and objective != "" and is_list(opts) do
    cond do
      Keyword.has_key?(opts, :blueprint) ->
        WorkflowBlueprint.from_input(Keyword.fetch!(opts, :blueprint))

      fallback_strategy?(opts) ->
        fallback_blueprint(workspace, objective, opts)

      true ->
        case generated_blueprint(workspace, objective, opts) do
          {:ok, blueprint} -> {:ok, blueprint}
          {:error, %Error{} = error} -> maybe_fallback(workspace, objective, opts, error)
        end
    end
  end

  @spec fallback_blueprint(Workspace.t(), String.t(), keyword()) ::
          {:ok, WorkflowBlueprint.t()} | {:error, Error.t()}
  def fallback_blueprint(%Workspace{} = workspace, objective, opts \\ []) do
    sources = normalize_sources(Keyword.get(opts, :input_paths, Keyword.get(opts, :inputs, [])))
    output_path = Keyword.get(opts, :output_path)
    write_policy = Keyword.get(opts, :write_policy, :docs_only)
    scorecard_params = scorecard_params(opts, output_path)
    id = Keyword.get(opts, :blueprint_id) || "assistant:generic_report"
    shape = fallback_shape(workspace, objective, sources, opts)

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
    BlueprintProposalPrompt.prompt(objective, capability_manifest(opts), opts)
  end

  @spec schema() :: keyword()
  def schema, do: BlueprintProposalPrompt.schema()

  @spec enforce_runtime_scorecard_params(WorkflowBlueprint.t(), keyword()) ::
          WorkflowBlueprint.t()
  def enforce_runtime_scorecard_params(%WorkflowBlueprint{} = blueprint, opts) do
    output_path = Keyword.get(opts, :output_path)
    runtime_params = scorecard_params(opts, output_path)

    components =
      Enum.map(blueprint.components, fn
        %ComponentBlueprint{type: type, params: params} = component
        when type in [:objective_scorecard, :verification] ->
          %{component | params: Map.merge(params || %{}, runtime_params)}

        component ->
          component
      end)

    %{blueprint | components: components}
  end

  defp generated_blueprint(%Workspace{} = workspace, objective, opts) do
    model = Keyword.get(opts, :model, @default_model)
    llm_opts = llm_opts(opts)
    manifest = capability_manifest(opts)

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
    RepairLoop.repair_blueprint_object(workspace, objective, manifest, object, error, opts)
  end

  defp validate_generated_candidate(object, opts, stage) do
    with {:ok, blueprint} <- WorkflowBlueprint.from_input(object),
         blueprint <- enforce_runtime_scorecard_params(blueprint, opts),
         {:ok, _report} <- BlueprintValidator.validate(blueprint, validation_opts(opts)) do
      {:ok, %{blueprint | metadata: Map.put(blueprint.metadata || %{}, :proposal_kind, stage)}}
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
               Map.put(blueprint.metadata || %{}, :proposal_failure, %{
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
        params: %{paths: Enum.map(sources, & &1.path)}
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
        params: %{paths: Enum.map(sources, & &1.path)}
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

  defp fallback_graph(_shape, sources, opts) do
    components = [
      ComponentBlueprint.new!("discover_sources", :source_discovery,
        params: %{paths: Enum.map(sources, & &1.path)}
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
            max_concurrency: Keyword.get(opts, :max_llm_map_concurrency, 1)
          }
          |> maybe_put_model(opts)
      ),
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
      %{from: "extract_slice_notes", to: "synthesize_report"}
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

  defp tabular_source?(%{path: path}) when is_binary(path), do: tabular_path?(path)
  defp tabular_source?(%{"path" => path}) when is_binary(path), do: tabular_path?(path)
  defp tabular_source?(path) when is_binary(path), do: tabular_path?(path)
  defp tabular_source?(_source), do: false

  defp tabular_path?(path) do
    extension = path |> Path.extname() |> String.downcase()
    extension in [".csv", ".jsonl", ".json"]
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

  defp scorecard_params(opts, output_path) do
    %{
      artifact_path: output_path,
      required_sections: Keyword.get(opts, :required_sections, []),
      required_source_cues:
        Keyword.get(opts, :required_source_cues, Keyword.get(opts, :source_cues, [])),
      require_artifact_quality?: Keyword.get(opts, :require_artifact_quality?, false)
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
    """
  end
end
