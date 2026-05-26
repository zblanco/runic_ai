defmodule RunicAI.RLM.StrategyRouter do
  @moduledoc """
  Deterministic strategy router for RLM-style coordinator work.

  The router intentionally starts as explicit, inspectable rules. It selects the
  least powerful strategy that looks likely to solve the task and returns
  enough metadata for traces and evaluations to compare routing quality.
  """

  alias RunicAI.Coding.Workspace

  @strategies [
    :direct_standard_agent,
    :lambda_workflow,
    :subagent_delegation,
    :generated_sandbox_component,
    :sandbox_repl,
    :host_edit_workflow
  ]

  @derive Jason.Encoder
  defstruct [
    :strategy,
    :confidence,
    :fallback,
    :reasons,
    :budgets,
    :metadata
  ]

  @type strategy ::
          :direct_standard_agent
          | :lambda_workflow
          | :subagent_delegation
          | :generated_sandbox_component
          | :sandbox_repl
          | :host_edit_workflow

  @type t :: %__MODULE__{
          strategy: strategy(),
          confidence: float(),
          fallback: strategy(),
          reasons: [atom()],
          budgets: map(),
          metadata: map()
        }

  @spec strategies() :: [strategy()]
  def strategies, do: @strategies

  @spec route(String.t(), keyword() | map()) :: t()
  def route(objective, opts) when is_list(opts) or is_map(opts), do: route(objective, nil, opts)

  @spec route(String.t(), Workspace.t() | nil, keyword() | map()) :: t()
  def route(objective, workspace, opts)
      when is_binary(objective) and objective != "" do
    opts = opts_map(opts)
    text = String.downcase(objective)
    source_count = source_count(opts)

    cond do
      generated_component?(text, opts) ->
        decision(
          :generated_sandbox_component,
          0.78,
          [:repeated_code_transform],
          opts,
          source_count,
          workspace
        )

      repl?(text, opts) ->
        decision(
          :sandbox_repl,
          0.72,
          [:unknown_decomposition, :exploratory_context],
          opts,
          source_count,
          workspace
        )

      subagents?(text, opts, source_count) ->
        decision(
          :subagent_delegation,
          0.74,
          [:partitionable_context],
          opts,
          source_count,
          workspace
        )

      lambda?(text, opts, source_count) ->
        decision(
          :lambda_workflow,
          0.76,
          [:known_split_map_reduce_shape],
          opts,
          source_count,
          workspace
        )

      host_edit?(text, opts) ->
        decision(
          :host_edit_workflow,
          0.7,
          [:host_workspace_mutation_required],
          opts,
          source_count,
          workspace
        )

      true ->
        decision(
          :direct_standard_agent,
          0.68,
          [:narrow_local_task],
          opts,
          source_count,
          workspace
        )
    end
  end

  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = decision) do
    %{
      strategy: decision.strategy,
      confidence: decision.confidence,
      fallback: decision.fallback,
      reasons: decision.reasons,
      budgets: decision.budgets,
      router: __MODULE__,
      routed_at: DateTime.utc_now(),
      metadata: decision.metadata
    }
  end

  defp decision(strategy, confidence, reasons, opts, source_count, workspace) do
    %__MODULE__{
      strategy: strategy,
      confidence: confidence,
      fallback: fallback(strategy),
      reasons: reasons,
      budgets: budgets(strategy, opts, source_count),
      metadata: %{
        source_count: source_count,
        workspace_root: workspace && workspace.root,
        deterministic?: true,
        model_assisted?: false
      }
    }
  end

  defp generated_component?(text, opts) do
    truthy?(get(opts, :repeated_transform?, false)) or
      contains_any?(text, [
        "reusable parser",
        "parser component",
        "analyzer",
        "scorer",
        "csv parser",
        "json parser",
        "generate a component",
        "generated component"
      ])
  end

  defp repl?(text, opts) do
    truthy?(get(opts, :exploratory?, false)) or
      contains_any?(text, [
        "explore",
        "unknown schema",
        "inspect artifact",
        "discover structure",
        "interactive",
        "repl",
        "probe the data"
      ])
  end

  defp subagents?(text, opts, source_count) do
    truthy?(get(opts, :delegate?, false)) or source_count >= 10 or
      contains_any?(text, [
        "subagent",
        "delegate",
        "parallel",
        "separate reviewers",
        "by component",
        "by file group",
        "independent investigation"
      ])
  end

  defp lambda?(text, opts, source_count) do
    truthy?(get(opts, :large_context?, false)) or source_count >= 3 or
      contains_any?(text, [
        "summarize",
        "extract",
        "classify",
        "compare",
        "score",
        "rank",
        "report",
        "split",
        "map reduce",
        "map/reduce"
      ])
  end

  defp host_edit?(text, opts) do
    truthy?(get(opts, :requires_mutation?, false)) or
      contains_any?(text, ["implement", "fix", "patch", "edit", "modify", "write tests"])
  end

  defp fallback(:direct_standard_agent), do: :lambda_workflow
  defp fallback(:lambda_workflow), do: :subagent_delegation
  defp fallback(:subagent_delegation), do: :lambda_workflow
  defp fallback(:generated_sandbox_component), do: :sandbox_repl
  defp fallback(:sandbox_repl), do: :subagent_delegation
  defp fallback(:host_edit_workflow), do: :direct_standard_agent

  defp budgets(:lambda_workflow, opts, source_count) do
    %{
      max_leaf_calls: get(opts, :max_leaf_calls, min(max(source_count, 1) * 3, 48)),
      max_depth: get(opts, :max_depth, 3),
      max_concurrency: get(opts, :max_concurrency, 8)
    }
  end

  defp budgets(:subagent_delegation, opts, source_count) do
    %{
      max_subagents: get(opts, :max_subagents, min(max(source_count, 2), 8)),
      max_review_passes: get(opts, :max_review_passes, 2)
    }
  end

  defp budgets(:sandbox_repl, opts, _source_count) do
    %{
      max_turns: get(opts, :max_repl_turns, 8),
      max_llm_calls: get(opts, :max_llm_calls, 20),
      max_exec_ms: get(opts, :max_exec_ms, 120_000)
    }
  end

  defp budgets(:generated_sandbox_component, opts, _source_count) do
    %{
      max_repair_attempts: get(opts, :max_repair_attempts, 4),
      require_tests?: get(opts, :require_tests?, true)
    }
  end

  defp budgets(_strategy, opts, _source_count) do
    %{
      max_turns: get(opts, :max_turns, 10),
      max_tool_calls: get(opts, :max_tool_calls, 20)
    }
  end

  defp source_count(opts) do
    opts
    |> get(:input_paths, get(opts, :sources, get(opts, :inputs, [])))
    |> List.wrap()
    |> length()
  end

  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))
  defp truthy?(value), do: value in [true, "true", 1, "1", "yes", "on"]

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
