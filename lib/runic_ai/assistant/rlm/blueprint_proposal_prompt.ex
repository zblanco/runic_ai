defmodule RunicAI.Assistant.RLM.BlueprintProposalPrompt do
  @moduledoc """
  Prompt and schema helpers for assistant workflow blueprint proposal.
  """

  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.FunctionBlueprint

  @spec schema() :: keyword()
  def schema do
    [
      id: [type: :string],
      objective: [type: :string, required: true],
      sources: [type: {:list, :map}],
      components: [type: {:list, :map}, required: true],
      edges: [type: {:list, :map}],
      stop_conditions: [type: {:list, :string}, required: true],
      policies: [type: :any],
      metadata: [type: :any]
    ]
  end

  @spec prompt(String.t(), map(), keyword()) :: String.t()
  def prompt(objective, manifest, opts \\ []) when is_binary(objective) and is_map(manifest) do
    """
    You are the RunicAI assistant RLM workflow coordinator.

    Objective:
    #{objective}

    Declared inputs:
    #{Jason.encode!(Keyword.get(opts, :input_paths, []))}

    Requested output:
    #{Jason.encode!(Keyword.get(opts, :output_path))}

    Required sections:
    #{Jason.encode!(Keyword.get(opts, :required_sections, []))}

    Required source cues:
    #{Jason.encode!(Keyword.get(opts, :required_source_cues, Keyword.get(opts, :source_cues, [])))}

    Capability manifest:
    #{Jason.encode!(manifest)}

    Return one workflow blueprint JSON object. The blueprint describes ordinary
    Runic workflow components as data; it must not contain generated Elixir
    modules or files.

    Required top-level shape:
    #{Jason.encode!(shape_example(opts))}

    Component rules:
    - components MUST be an array of objects with id, type, and params.
    - type MUST be one of the manifest component names.
    - edges MUST be an array of objects with from and to fields.
    - stop_conditions MUST be a non-empty array of strings.
    - policies and metadata MUST be objects.
    - generated functions may use Tier 0 built-ins and Tier 1 expression
      blueprints. Do not emit Tier 2 source unless explicitly requested.
    - prefer `source_discovery` before directory, glob, repository, or
      multi-file inputs.
    - prefer `tabular_parser`, `record_map`, and `record_group` for CSV, JSONL,
      support tickets, and cleanup tasks.
    - use `record_map` to normalize per-record facts before `record_group`;
      preserve original identifiers, names, addresses, timelines, policy terms,
      and invalid values when the objective asks for cleanup or comparison.
    - prefer `document_compare` for old/new or multi-document comparison tasks.
    - prefer `report_composer` when deterministic section assembly is enough;
      use `llm_leaf` when synthesis needs a model.
    - do not connect raw `source_discovery`, `tabular_parser`, or
      `document_compare` output directly to `report_composer` unless the output
      is already human-readable prose. Use `llm_map`, `record_map` with a
      prompt, or `llm_leaf` first when the objective asks for decisions,
      themes, implications, summaries, cleanup rationale, or stakeholder
      analysis.
    - include an `artifact_writer` when an output path is requested.
    - end with `objective_scorecard` or `verification` so success is checked by
      artifact/section/schema/source evidence, not by a model completion claim.
    - pass `required_source_cues` and `require_artifact_quality?` through to
      the scorecard whenever they are present in the manifest.

    Generic valid component examples:
    #{Jason.encode!(component_examples(opts))}

    Return only valid JSON. Do not wrap it in Markdown fences and do not add
    prose outside the JSON object.
    """
  end

  @spec repair_prompt(String.t(), map(), map() | term(), [map()], keyword()) :: String.t()
  def repair_prompt(objective, manifest, invalid_object, diagnostics, opts \\ []) do
    """
    You are repairing an invalid RunicAI assistant workflow blueprint.

    Objective:
    #{objective}

    Capability manifest:
    #{Jason.encode!(manifest)}

    Validation diagnostics:
    #{Jason.encode!(diagnostics)}

    Previous invalid object:
    #{Jason.encode!(json_safe(invalid_object))}

    Return a complete corrected workflow blueprint JSON object. Preserve the
    user's requested inputs and output where possible. Repair only the invalid
    graph, component, policy, or function shape. Prefer Tier 0/Tier 1 functions
    and generic RunicAI.RLM.Components. Include non-empty stop_conditions and an
    objective_scorecard or verification component. Return only JSON.

    Required top-level shape:
    #{Jason.encode!(shape_example(opts))}
    """
  end

  defp shape_example(opts) do
    %{
      id: "assistant:generated_workflow",
      objective: "user objective here",
      sources:
        Enum.map(Keyword.get(opts, :input_paths, []), fn path ->
          %{id: Path.basename(path), path: path}
        end),
      components: [
        %{
          id: "discover",
          type: "source_discovery",
          params: %{paths: Keyword.get(opts, :input_paths, [])}
        },
        %{
          id: "split",
          type: "source_splitter",
          params: %{strategy: "markdown_heading", max_bytes: 8000}
        },
        %{id: "materialize", type: "source_materializer", params: %{}},
        %{
          id: "extract",
          type: "llm_map",
          params: %{prompt: "Extract objective-relevant notes from {{text}}."}
        },
        %{
          id: "synthesize",
          type: "llm_leaf",
          params: %{
            strategy: "llm_reduce",
            prompt: "Write the requested report from these notes: {{items}}"
          }
        },
        %{id: "write", type: "artifact_writer", params: %{path: Keyword.get(opts, :output_path)}},
        %{
          id: "score",
          type: "objective_scorecard",
          params: %{
            artifact_path: Keyword.get(opts, :output_path),
            required_sections: Keyword.get(opts, :required_sections, []),
            required_source_cues:
              Keyword.get(opts, :required_source_cues, Keyword.get(opts, :source_cues, [])),
            require_artifact_quality?: Keyword.get(opts, :require_artifact_quality?, false)
          }
        }
      ],
      edges: [
        %{from: "discover", to: "split"},
        %{from: "split", to: "materialize"},
        %{from: "materialize", to: "extract"},
        %{from: "extract", to: "synthesize"},
        %{from: "synthesize", to: "write"},
        %{from: "write", to: "score"}
      ],
      stop_conditions: ["artifact written", "objective scorecard satisfied"],
      policies: %{
        generated_functions: %{max_tier: "tier1"},
        budgets: %{max_nodes: 20, max_llm_calls: 80, max_runtime_ms: 900_000}
      },
      metadata: %{proposal_kind: "generated"}
    }
  end

  defp component_examples(opts) do
    [
      %{
        id: "discover",
        type: "source_discovery",
        params: %{paths: Keyword.get(opts, :input_paths, [])}
      },
      %{
        id: "split",
        type: "source_splitter",
        params: %{strategy: "markdown_heading", max_bytes: 8000}
      },
      %{id: "parse", type: "tabular_parser", params: %{format: "jsonl"}},
      %{
        id: "classify",
        type: "record_map",
        params: %{
          prompt:
            "For objective {{objective}}, turn this record into concise analysis: {{record}}."
        }
      },
      %{
        id: "group",
        type: "record_group",
        params: %{group_by: "theme", dedupe_by: ["ticket_id"], sort_by: "severity"}
      },
      %{
        id: "transform",
        type: "blueprint_transform",
        params: %{function: %{tier: "tier1", expr: %{op: "get", path: ["records"]}}}
      },
      %{id: "compare", type: "document_compare", params: %{}},
      %{
        id: "compose",
        type: "report_composer",
        params: %{title: "Report", sections: Keyword.get(opts, :required_sections, ["Summary"])}
      },
      %{id: "write", type: "artifact_writer", params: %{path: Keyword.get(opts, :output_path)}},
      %{
        id: "score",
        type: "objective_scorecard",
        params: %{
          artifact_path: Keyword.get(opts, :output_path),
          required_source_cues:
            Keyword.get(opts, :required_source_cues, Keyword.get(opts, :source_cues, [])),
          require_artifact_quality?: Keyword.get(opts, :require_artifact_quality?, false)
        }
      }
    ]
  end

  defp json_safe(value) do
    case Jason.encode(value) do
      {:ok, _json} -> value
      {:error, _error} -> inspect(value, limit: 40, printable_limit: 2_000)
    end
  end

  @spec manifest(keyword()) :: map()
  def manifest(opts \\ []) do
    %{
      components: Enum.map(ComponentBlueprint.types(), &Atom.to_string/1),
      function_tiers: Enum.map(FunctionBlueprint.tiers(), &Atom.to_string/1),
      tier0_operations: Enum.map(FunctionBlueprint.tier0_ops(), &Atom.to_string/1),
      default_model: Keyword.get(opts, :model, "openai:gpt-5.4-mini"),
      max_generated_function_tier: Keyword.get(opts, :max_generated_function_tier, :tier1),
      write_policy: Keyword.get(opts, :write_policy, :docs_only),
      output_path: Keyword.get(opts, :output_path),
      input_paths: Keyword.get(opts, :input_paths, []),
      required_sections: Keyword.get(opts, :required_sections, []),
      required_source_cues:
        Keyword.get(opts, :required_source_cues, Keyword.get(opts, :source_cues, [])),
      require_artifact_quality?: Keyword.get(opts, :require_artifact_quality?, false)
    }
  end
end
