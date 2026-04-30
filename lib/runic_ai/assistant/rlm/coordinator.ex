defmodule RunicAI.Assistant.RLM.Coordinator do
  @moduledoc """
  General assistant RLM coordinator.

  The first implementation keeps proposal generation conservative: callers may
  provide a full blueprint, otherwise the coordinator builds a generic
  split/map/reduce/write/verify graph from the objective, declared sources, and
  output target.
  """

  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @default_split_bytes 8_000

  @spec propose(Workspace.t(), String.t(), keyword()) ::
          {:ok, WorkflowBlueprint.t()} | {:error, Error.t()}
  def propose(%Workspace{} = workspace, objective, opts \\ [])
      when is_binary(objective) and objective != "" and is_list(opts) do
    case Keyword.get(opts, :blueprint) do
      nil -> fallback_blueprint(workspace, objective, opts)
      blueprint -> WorkflowBlueprint.from_input(blueprint)
    end
  end

  @spec fallback_blueprint(Workspace.t(), String.t(), keyword()) ::
          {:ok, WorkflowBlueprint.t()} | {:error, Error.t()}
  def fallback_blueprint(%Workspace{} = _workspace, objective, opts \\ []) do
    sources = normalize_sources(Keyword.get(opts, :input_paths, Keyword.get(opts, :inputs, [])))
    output_path = Keyword.get(opts, :output_path)
    write_policy = Keyword.get(opts, :write_policy, :docs_only)
    required_sections = Keyword.get(opts, :required_sections, [])
    id = Keyword.get(opts, :blueprint_id) || "assistant:generic_report"

    components =
      [
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
              limit: Keyword.get(opts, :max_llm_map_calls, 80)
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
      |> maybe_append_writer(output_path, write_policy)
      |> append_verification(output_path, required_sections)

    edges =
      [
        %{from: "split_sources", to: "materialize_slices"},
        %{from: "materialize_slices", to: "extract_slice_notes"},
        %{from: "extract_slice_notes", to: "synthesize_report"}
      ]
      |> maybe_append_writer_edges(output_path)
      |> append_verification_edges(output_path)

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
        proposal_kind: :generic_split_map_reduce_report,
        capability_manifest: capability_manifest(opts)
      }
    )
  end

  @spec capability_manifest(keyword()) :: map()
  def capability_manifest(opts \\ []) do
    %{
      components: [
        :source_splitter,
        :source_materializer,
        :llm_map,
        :llm_leaf,
        :blueprint_transform,
        :blueprint_reduce,
        :artifact_writer,
        :verification
      ],
      function_tiers: [:tier0, :tier1],
      write_policy: Keyword.get(opts, :write_policy, :docs_only),
      default_model: Keyword.get(opts, :model, "openai:gpt-5.4-mini")
    }
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

  defp maybe_append_writer(components, nil, _write_policy), do: components
  defp maybe_append_writer(components, "", _write_policy), do: components

  defp maybe_append_writer(components, output_path, write_policy) do
    components ++
      [
        ComponentBlueprint.new!("write_artifact", :artifact_writer,
          params: %{path: output_path, write_policy: write_policy}
        )
      ]
  end

  defp append_verification(components, output_path, required_sections) do
    components ++
      [
        ComponentBlueprint.new!("verify_objective", :verification,
          params: %{artifact_path: output_path, required_sections: required_sections}
        )
      ]
  end

  defp maybe_append_writer_edges(edges, nil), do: edges
  defp maybe_append_writer_edges(edges, ""), do: edges

  defp maybe_append_writer_edges(edges, _output_path) do
    edges ++ [%{from: "synthesize_report", to: "write_artifact"}]
  end

  defp append_verification_edges(edges, nil),
    do: edges ++ [%{from: "synthesize_report", to: "verify_objective"}]

  defp append_verification_edges(edges, ""),
    do: edges ++ [%{from: "synthesize_report", to: "verify_objective"}]

  defp append_verification_edges(edges, _output_path) do
    edges ++ [%{from: "write_artifact", to: "verify_objective"}]
  end

  defp stop_conditions(nil),
    do: ["final assistant output produced", "objective scorecard checked"]

  defp stop_conditions(""), do: stop_conditions(nil)

  defp stop_conditions(_output_path) do
    ["artifact written", "objective scorecard checked"]
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
