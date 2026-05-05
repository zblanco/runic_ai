defmodule RunicAI.Assistant.RLM.BlueprintProposalPrompt do
  @moduledoc """
  Prompt and schema helpers for assistant workflow blueprint proposal.
  """

  alias RunicAI.Assistant.RLM.FunctionBlueprint
  alias RunicAI.RLM.ComponentCatalog

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
    You are the RunicAI assistant RLM workflow coordinator. I.e. your job is to compose a workflow of components to
    competently achieve the objective. RunicAI has a suite of many useful components that can fit together in various dataflow
    constructs like lambda steps, rules, map + reduce, accumulators/sinks, state machines + FSM, and more.

    Objective:
    #{objective}

    Conversation context:
    #{conversation_context(opts)}

    Conversation history JSON:
    #{Jason.encode!(Keyword.get(opts, :conversation_history, []))}

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
    modules or files. Always return a workflow blueprint. Do not answer the
    user directly outside the blueprint.

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
    - for simple conversational requests with no declared inputs, use a small
      workflow such as `llm_leaf` -> `objective_scorecard`; the `llm_leaf`
      prompt should answer using `{{objective}}` and the available
      `{{input}}` conversation context.
    - when the user asks to continue, revise, expand, or refer to "this",
      "that", "the outline", "the previous answer", or similar prior-turn
      references, choose workflow nodes that explicitly consume
      `conversation_history` or `conversation_context` from the assistant input.
    - the local harness can use read-only source components for declared input
      paths and explicit readable paths in the objective, including paths
      outside the project root when the runtime policy allows them. Do not
      claim you cannot access declared local paths; use source components and
      preserve provenance.
    - read-only source discovery, splitting, and materialization do not require
      HITL. Artifact writes, destructive commands, and side-effecting actions
      must use the review/HITL path according to the write policy.
    - prefer `source_discovery` before directory, glob, repository, or
      multi-file inputs.
    - for repository or directory analysis, use
      `source_discovery -> source_splitter -> source_materializer` before any
      LLM map or synthesis. Never connect raw `source_discovery` output, or a
      transform of raw discovery output, directly to `source_materializer`.
      Use `max_depth` and `max_files` on `source_discovery` for repository
      trees so README, mix.exs, package manifests, docs, and source files can
      be discovered.
    - prefer `tabular_parser`, `record_map`, and `record_group` for CSV, JSONL,
      support tickets, and cleanup tasks.
    - use `record_map` to normalize per-record facts before `record_group`;
      preserve original identifiers, names, addresses, timelines, policy terms,
      and invalid values when the objective asks for cleanup or comparison.
    - prefer `document_compare` for old/new or multi-document comparison tasks.
    - `llm_map` and `record_map` are native Runic map components. Fan them into
      `blueprint_reduce` before connecting to synthesis, composition, artifact,
      or scorecard nodes.
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

    Conversation context:
    #{conversation_context(opts)}

    Conversation history JSON:
    #{Jason.encode!(Keyword.get(opts, :conversation_history, []))}

    Capability manifest:
    #{Jason.encode!(manifest)}

    Validation diagnostics:
    #{Jason.encode!(json_safe(diagnostics))}

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
    if simple_conversation_shape?(opts) do
      simple_conversation_shape_example(opts)
    else
      source_shape_example(opts)
    end
  end

  defp source_shape_example(opts) do
    output_path = Keyword.get(opts, :output_path)

    components =
      [
        %{
          id: "discover",
          type: "source_discovery",
          params: %{
            paths: Keyword.get(opts, :input_paths, []),
            max_depth: 3,
            max_files: 96
          }
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
          id: "join_notes",
          type: "blueprint_reduce",
          params: %{strategy: "join"}
        },
        %{
          id: "synthesize",
          type: "llm_leaf",
          params: %{
            strategy: "llm_reduce",
            prompt: "Write the requested report from these notes: {{items}}"
          }
        }
      ] ++
        writer_example_components(output_path) ++
        [
          %{
            id: "score",
            type: "objective_scorecard",
            params: %{
              artifact_path: output_path,
              required_sections: Keyword.get(opts, :required_sections, []),
              required_source_cues:
                Keyword.get(opts, :required_source_cues, Keyword.get(opts, :source_cues, [])),
              require_artifact_quality?: Keyword.get(opts, :require_artifact_quality?, false)
            }
          }
        ]

    edges =
      [
        %{from: "discover", to: "split"},
        %{from: "split", to: "materialize"},
        %{from: "materialize", to: "extract"},
        %{from: "extract", to: "join_notes"},
        %{from: "join_notes", to: "synthesize"}
      ] ++ writer_example_edges(output_path)

    %{
      id: "assistant:generated_workflow",
      objective: "user objective here",
      sources:
        Enum.map(Keyword.get(opts, :input_paths, []), fn path ->
          %{id: Path.basename(path), path: path}
        end),
      components: components,
      edges: edges,
      stop_conditions: stop_conditions(output_path),
      policies: %{
        generated_functions: %{max_tier: "tier1"},
        budgets: %{max_nodes: 20, max_llm_calls: 80, max_runtime_ms: 900_000}
      },
      metadata: %{proposal_kind: "generated"}
    }
  end

  defp simple_conversation_shape_example(opts) do
    %{
      id: "assistant:conversation_response",
      objective: "user objective here",
      sources: [],
      components: [
        %{
          id: "respond",
          type: "llm_leaf",
          params: %{
            strategy: "llm_reduce",
            group_prompt:
              "Prepare answer context for {{objective}} from the assistant input: {{input}}.",
            prompt:
              "Answer the current request. Use prior conversation only when relevant. Objective: {{objective}}\nContext: {{items}}",
            max_group_items: 1
          }
        },
        %{
          id: "score",
          type: "objective_scorecard",
          params: %{
            required_sections: Keyword.get(opts, :required_sections, []),
            required_source_cues:
              Keyword.get(opts, :required_source_cues, Keyword.get(opts, :source_cues, [])),
            require_artifact_quality?: Keyword.get(opts, :require_artifact_quality?, false)
          }
        }
      ],
      edges: [%{from: "respond", to: "score"}],
      stop_conditions: ["assistant response produced"],
      policies: %{
        generated_functions: %{max_tier: "tier1"},
        budgets: %{max_nodes: 4, max_llm_calls: 3, max_runtime_ms: 120_000}
      },
      metadata: %{proposal_kind: "conversation_response"}
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
      %{id: "join_classifications", type: "blueprint_reduce", params: %{strategy: "join"}},
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
        id: "respond",
        type: "llm_leaf",
        params: %{
          strategy: "llm_reduce",
          group_prompt:
            "Prepare response context for {{objective}} from the assistant input: {{input}}.",
          prompt:
            "Answer the current request. Use prior conversation only when relevant. Objective: {{objective}}\nContext: {{items}}",
          max_group_items: 1
        }
      },
      %{
        id: "compose",
        type: "report_composer",
        params: %{title: "Report", sections: Keyword.get(opts, :required_sections, ["Summary"])}
      }
    ] ++
      writer_example_components(Keyword.get(opts, :output_path)) ++
      [
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

  defp writer_example_components(nil), do: []
  defp writer_example_components(""), do: []

  defp writer_example_components(output_path) do
    [%{id: "write", type: "artifact_writer", params: %{path: output_path}}]
  end

  defp simple_conversation_shape?(opts) do
    empty_listish?(Keyword.get(opts, :input_paths, [])) and
      empty_listish?(Keyword.get(opts, :inputs, [])) and
      blank?(Keyword.get(opts, :output_path))
  end

  defp empty_listish?(nil), do: true
  defp empty_listish?([]), do: true
  defp empty_listish?(value), do: value in ["", false]

  defp blank?(value), do: is_nil(value) or value == ""

  defp conversation_context(opts) do
    case Keyword.get(opts, :conversation_context, "") do
      "" -> "[]"
      nil -> "[]"
      context -> context
    end
  end

  defp writer_example_edges(nil), do: [%{from: "synthesize", to: "score"}]
  defp writer_example_edges(""), do: writer_example_edges(nil)

  defp writer_example_edges(_output_path) do
    [%{from: "synthesize", to: "write"}, %{from: "write", to: "score"}]
  end

  defp stop_conditions(nil),
    do: ["final assistant output produced", "objective scorecard satisfied"]

  defp stop_conditions(""), do: stop_conditions(nil)
  defp stop_conditions(_output_path), do: ["artifact written", "objective scorecard satisfied"]

  defp json_safe(value), do: json_safe(value, 0)

  defp json_safe(_value, depth) when depth > 8, do: "[depth limit]"

  defp json_safe(value, _depth) when is_nil(value) or is_boolean(value) or is_number(value),
    do: value

  defp json_safe(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value, _depth) when is_binary(value) do
    if String.valid?(value) do
      truncate(value)
    else
      "[binary #{byte_size(value)} bytes]"
    end
  end

  defp json_safe(%DateTime{} = value, _depth), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value, _depth), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Date{} = value, _depth), do: Date.to_iso8601(value)
  defp json_safe(%Time{} = value, _depth), do: Time.to_iso8601(value)

  defp json_safe(%module{} = value, depth) do
    value
    |> Map.from_struct()
    |> Map.put(:__struct__, inspect(module))
    |> json_safe(depth + 1)
  end

  defp json_safe(value, depth) when is_list(value) do
    value
    |> Enum.take(100)
    |> Enum.map(&json_safe(&1, depth + 1))
  end

  defp json_safe(value, depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> json_safe(depth + 1)
  end

  defp json_safe(value, depth) when is_map(value) do
    value
    |> Enum.take(100)
    |> Map.new(fn {key, val} -> {json_safe_key(key), json_safe(val, depth + 1)} end)
  end

  defp json_safe(value, _depth), do: inspect(value, limit: 40, printable_limit: 2_000)

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key), do: inspect(key)

  defp truncate(value) do
    if byte_size(value) > 8_192 do
      binary_part(value, 0, 8_192) <> "...[truncated]"
    else
      value
    end
  end

  @spec manifest(keyword()) :: map()
  def manifest(opts \\ []) do
    %{
      components: Enum.map(ComponentCatalog.types(), &Atom.to_string/1),
      function_tiers: Enum.map(FunctionBlueprint.tiers(), &Atom.to_string/1),
      tier0_operations: Enum.map(FunctionBlueprint.tier0_ops(), &Atom.to_string/1),
      default_model: Keyword.get(opts, :model, "openai:gpt-5.4-mini"),
      max_generated_function_tier: Keyword.get(opts, :max_generated_function_tier, :tier1),
      write_policy: Keyword.get(opts, :write_policy, :docs_only),
      output_path: Keyword.get(opts, :output_path),
      input_paths: Keyword.get(opts, :input_paths, []),
      inferred_input_paths: Keyword.get(opts, :inferred_input_paths, []),
      read_policy: %{
        local_read_components: ["source_discovery", "source_splitter", "source_materializer"],
        hitl_required_for: ["artifact_writes", "destructive_commands", "side_effecting_actions"]
      },
      required_sections: Keyword.get(opts, :required_sections, []),
      required_source_cues:
        Keyword.get(opts, :required_source_cues, Keyword.get(opts, :source_cues, [])),
      require_artifact_quality?: Keyword.get(opts, :require_artifact_quality?, false)
    }
  end
end
