defmodule RunicAI.RLM.SandboxEvaluationFixtures do
  @moduledoc """
  Deterministic sandbox/RLM evaluation fixtures.

  These fixtures are intentionally data-only. They give Phase 8 a repeatable
  benchmark shape for comparing coordinator strategies before live backends are
  involved. Each fixture carries the same contract surfaces the real runtime
  uses: router decisions, Lambda plans, subagent assignments, REPL state,
  generated-component promotion decisions, planned metrics, and actual metrics.
  """

  alias RunicAI.RLM.ContextSliceContract
  alias RunicAI.RLM.CostEstimate
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.LambdaPlan
  alias RunicAI.RLM.Policy
  alias RunicAI.RLM.REPL.State
  alias RunicAI.RLM.StrategyRouter
  alias RunicAI.RLM.SubagentAssignment
  alias RunicAI.Evaluation.Case
  alias RunicAI.Evaluation.Result
  alias RunicAI.Evaluation.Run
  alias RunicAI.ReviewDecision
  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentCatalog
  alias RunicAI.Sandbox.GeneratedComponentPromotionPolicy

  @scenario_ids [
    "bad_sandbox_code_repair",
    "lambda_report_generation",
    "lambda_codebase_risk_inventory",
    "lambda_provenance_reextract",
    "subagent_file_group_review",
    "repl_unknown_schema",
    "repl_context_discovery",
    "generated_component_promotion_denied",
    "generated_component_promotion_flywheel",
    "sandbox_proxy_service_smoke",
    "checkpoint_restore_after_failure",
    "strategy_family_report"
  ]

  @comparison_harnesses [
    :direct_standard_agent,
    :dynamic_workflow_coordinator,
    :lambda_workflow,
    :subagent_delegation,
    :sandbox_repl,
    :generated_sandbox_component
  ]

  @type scenario :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:objective) => String.t(),
          required(:expected_strategy) => StrategyRouter.strategy(),
          required(:router_opts) => map(),
          required(:fixtures) => map(),
          required(:comparison_harnesses) => [atom()],
          required(:harness_specs) => map(),
          required(:evidence_requirements) => [atom()],
          required(:metadata) => map()
        }

  @type evaluation_record :: %{
          required(:fixture_id) => String.t(),
          required(:harness) => atom(),
          required(:strategy) => atom(),
          required(:router_decision) => map(),
          required(:planned) => map(),
          required(:actual) => map(),
          required(:deltas) => map(),
          required(:quality) => map(),
          required(:strategy_changed?) => boolean(),
          required(:review_notes) => [String.t()],
          required(:artifact_refs) => [term()]
        }

  @spec scenario_ids() :: [String.t()]
  def scenario_ids, do: @scenario_ids

  @spec comparison_harnesses() :: [atom()]
  def comparison_harnesses, do: @comparison_harnesses

  @spec scenarios() :: [scenario()]
  def scenarios, do: Enum.map(@scenario_ids, &get!/1)

  @spec get(String.t() | atom()) :: {:ok, scenario()} | {:error, term()}
  def get(id) when is_atom(id), do: get(Atom.to_string(id))

  def get(id) when is_binary(id) do
    case id do
      "bad_sandbox_code_repair" -> {:ok, bad_sandbox_code_repair()}
      "lambda_report_generation" -> {:ok, lambda_report_generation()}
      "lambda_codebase_risk_inventory" -> {:ok, lambda_codebase_risk_inventory()}
      "lambda_provenance_reextract" -> {:ok, lambda_provenance_reextract()}
      "subagent_file_group_review" -> {:ok, subagent_file_group_review()}
      "repl_unknown_schema" -> {:ok, repl_unknown_schema()}
      "repl_context_discovery" -> {:ok, repl_context_discovery()}
      "generated_component_promotion_denied" -> {:ok, generated_component_promotion_denied()}
      "generated_component_promotion_flywheel" -> {:ok, generated_component_promotion_flywheel()}
      "sandbox_proxy_service_smoke" -> {:ok, sandbox_proxy_service_smoke()}
      "checkpoint_restore_after_failure" -> {:ok, checkpoint_restore_after_failure()}
      "strategy_family_report" -> {:ok, strategy_family_report()}
      _other -> {:error, {:unknown_sandbox_evaluation_fixture, id}}
    end
  end

  @spec get!(String.t() | atom()) :: scenario()
  def get!(id) do
    case get(id) do
      {:ok, scenario} -> scenario
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @spec route(scenario() | String.t() | atom()) :: StrategyRouter.t()
  def route(scenario_or_id) do
    scenario_or_id
    |> scenario!()
    |> then(&StrategyRouter.route(&1.objective, &1.router_opts))
  end

  @spec comparison_records(scenario() | String.t() | atom(), map()) :: [evaluation_record()]
  def comparison_records(scenario_or_id, actual_by_harness \\ %{})
      when is_map(actual_by_harness) do
    scenario = scenario!(scenario_or_id)
    router_decision = router_summary(route(scenario))

    Enum.map(scenario.comparison_harnesses, fn harness ->
      spec = Map.fetch!(scenario.harness_specs, harness)
      actual = Map.get(actual_by_harness, harness, spec.actual)

      %{
        fixture_id: scenario.id,
        harness: harness,
        strategy: spec.strategy,
        router_decision: router_decision,
        planned: spec.planned,
        actual: actual,
        deltas: metric_deltas(spec.planned, actual),
        quality: spec.quality,
        strategy_changed?: strategy_changed?(spec.strategy, actual),
        review_notes: spec.review_notes,
        artifact_refs: spec.artifact_refs
      }
    end)
  end

  @spec evaluation_run(scenario() | String.t() | atom(), keyword()) :: Run.t()
  def evaluation_run(scenario_or_id, opts \\ []) when is_list(opts) do
    scenario = scenario!(scenario_or_id)
    records = comparison_records(scenario, Keyword.get(opts, :actual_by_harness, %{}))
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now())
    completed_at = Keyword.get(opts, :completed_at, DateTime.utc_now())

    cases = Enum.map(records, &evaluation_case(scenario, &1))
    results = Enum.map(records, &evaluation_result(scenario, &1))

    Run.new!(
      id: Keyword.get(opts, :id, "sandbox-eval:#{scenario.id}"),
      recipe: __MODULE__,
      policy: %{fixture_only?: true, live_backend_required?: false},
      cases: cases,
      results: results,
      aggregate: aggregate(records),
      started_at: started_at,
      completed_at: completed_at,
      metadata: %{
        fixture_id: scenario.id,
        expected_strategy: scenario.expected_strategy,
        router_decision: router_summary(route(scenario)),
        comparison_harnesses: scenario.comparison_harnesses,
        evidence_requirements: scenario.evidence_requirements,
        deterministic?: true,
        live_backend_required?: false
      }
    )
  end

  @spec write_evaluation_artifacts!(scenario() | String.t() | atom(), Path.t(), keyword()) ::
          map()
  def write_evaluation_artifacts!(scenario_or_id, output_dir, opts \\ [])
      when is_binary(output_dir) and is_list(opts) do
    run = evaluation_run(scenario_or_id, opts)
    File.mkdir_p!(output_dir)

    basename = Keyword.get(opts, :basename, run.id |> String.replace(":", "-"))
    json_path = Path.join(output_dir, "#{basename}.json")
    markdown_path = Path.join(output_dir, "#{basename}.md")

    File.write!(json_path, Jason.encode!(run_payload(run), pretty: true))
    File.write!(markdown_path, markdown(run))

    %{run: run, json_path: json_path, markdown_path: markdown_path}
  end

  @spec run_payload(Run.t()) :: map()
  def run_payload(%Run{} = run) do
    %{
      id: run.id,
      recipe: inspect(run.recipe),
      policy: run.policy,
      aggregate: run.aggregate,
      started_at: timestamp(run.started_at),
      completed_at: timestamp(run.completed_at),
      metadata: run.metadata,
      cases:
        Enum.map(run.cases, fn %Case{} = evaluation_case ->
          %{
            id: evaluation_case.id,
            input: evaluation_case.input,
            expected: Enum.map(evaluation_case.expected, &expectation_payload/1),
            tags: evaluation_case.tags,
            metadata: evaluation_case.metadata
          }
        end),
      results:
        Enum.map(run.results, fn %Result{} = result ->
          %{
            case_id: result.case_id,
            status: result.status,
            outputs: result.outputs,
            scores: result.scores,
            metrics: result.metrics,
            failures: result.failures,
            metadata: result.metadata
          }
        end)
    }
  end

  @spec markdown(Run.t()) :: String.t()
  def markdown(%Run{} = run) do
    rows =
      Enum.map(run.results, fn %Result{} = result ->
        [
          result.metadata.harness,
          result.metadata.strategy,
          result.status,
          score(result),
          result.metrics.model_calls,
          result.metrics.sandbox_calls,
          result.metrics.latency_ms,
          result.metrics.review_pauses,
          result.metrics.strategy_changed?
        ]
        |> Enum.map(&to_string/1)
        |> Enum.join(" | ")
      end)

    """
    # Sandbox/RLM Strategy Evaluation

    Run: `#{run.id}`

    Fixture: `#{run.metadata.fixture_id}`

    Router strategy: `#{run.metadata.router_decision.strategy}`

    Fallback strategy: `#{run.metadata.router_decision.fallback}`

    | Harness | Strategy | Status | Quality | Model calls | Sandbox calls | Latency ms | Review pauses | Strategy changed |
    | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
    #{Enum.map_join(rows, "\n", &("| " <> &1 <> " |"))}

    ## Aggregate

    - cases: #{run.aggregate.cases}
    - passed: #{run.aggregate.passed}
    - failed: #{run.aggregate.failed}
    - success_rate: #{run.aggregate.success_rate}
    - average_quality: #{run.aggregate.average_quality}
    - model_calls: #{run.aggregate.model_calls}
    - sandbox_calls: #{run.aggregate.sandbox_calls}
    - review_pauses: #{run.aggregate.review_pauses}
    - strategy_changes: #{run.aggregate.strategy_changes}
    - host_mutations_avoided: #{run.aggregate.host_mutations_avoided}
    #{generated_component_flywheel_section(run)}
    """
  end

  defp generated_component_flywheel_section(%Run{} = run) do
    run.results
    |> Enum.map(& &1.metrics)
    |> Enum.find(&Map.has_key?(&1, :reuse_rate))
    |> case do
      nil ->
        ""

      metrics ->
        promotion_decisions = Map.get(metrics, :promotion_decisions, %{})

        """

        ## Generated Component Flywheel

        - runs: #{Map.get(metrics, :runs, 0)}
        - generated_components: #{Map.get(metrics, :generated_components, 0)}
        - promoted_components: #{Map.get(metrics, :promoted_components, 0)}
        - catalog_hits: #{Map.get(metrics, :catalog_hits, 0)}
        - reused_components: #{Map.get(metrics, :reused_components, 0)}
        - proof_pass_rate: #{Map.get(metrics, :proof_pass_rate, 0.0)}
        - reuse_rate: #{Map.get(metrics, :reuse_rate, 0.0)}
        - repair_count: #{Map.get(metrics, :repair_count, 0)}
        - workflow_completion_rate: #{Map.get(metrics, :workflow_completion_rate, 0.0)}
        - promotion_decisions: #{inspect(promotion_decisions)}
        """
    end
  end

  @spec lambda_report_plan() :: LambdaPlan.t()
  def lambda_report_plan do
    source_ref =
      EnvironmentRef.new!(__MODULE__, "report-source-bundle",
        label: "report source bundle",
        metadata: %{source_kind: :document, fixture_id: "lambda_report_generation"}
      )

    contract =
      ContextSliceContract.new!(source_ref,
        id: "context-slice:report-source-bundle",
        source_kind: :document,
        token_budget: 4_000,
        expected_output_schema: %{type: :risk_record, required: [:claim, :evidence]},
        merge_policy: %{reducer: :merge_claims, conflict_policy: :retain_conflicts},
        review_policy: %{checks: [:coverage, :specificity, :provenance]},
        metadata: %{fixture_id: "lambda_report_generation"}
      )

    policy =
      Policy.new!(
        leaf_window: 4_000,
        max_depth: 2,
        max_branching_factor: 3,
        max_leaf_calls: 6,
        max_reduce_calls: 1,
        max_environment_reads: 3,
        concurrency: 3,
        allowed_combinators: [:split, :map, :reduce, :review, :generate],
        review_policy: %{required?: true, max_retries_per_slice: 1},
        metadata: %{fixture_id: "lambda_report_generation"}
      )

    cost_estimate =
      CostEstimate.new!(
        leaf_calls: 6,
        reducer_calls: 1,
        environment_reads: 3,
        input_tokens: 24_000,
        output_tokens: 4_000,
        latency_class: :bounded_parallel,
        confidence: 0.86,
        assumptions: [
          "three source groups split into two leaf chunks each",
          "one reducer call and one review pass"
        ],
        metadata: %{fixture_id: "lambda_report_generation"}
      )

    LambdaPlan.new!(
      "Extract risks from source bundle sections and write a reviewed report",
      :report_generation,
      [source_ref],
      id: "lambda-plan:report-generation-fixture",
      operators: [
        %{op: :split, by: :source_group, target_tokens: 4_000},
        %{op: :map, component: :llm_extract, schema: :risk_record},
        %{op: :reduce, reducer: :merge_claims},
        %{op: :review, checks: [:coverage, :specificity, :provenance]},
        %{op: :generate, component: :report_composer}
      ],
      context_contracts: [contract],
      policy: policy,
      cost_estimate: cost_estimate,
      detection: %{task_shape: :template_report, structure_known?: true},
      budgets: %{max_leaf_calls: 6, max_depth: 2, max_concurrency: 3},
      estimates: %{leaf_calls: 6, reduce_calls: 1, review_calls: 1, sandbox_executions: 0},
      fallback_strategy: :subagent_delegation,
      metadata: %{fixture_id: "lambda_report_generation"}
    )
  end

  @spec lambda_codebase_risk_plan() :: LambdaPlan.t()
  def lambda_codebase_risk_plan do
    refs =
      ["web", "runtime", "sandbox", "agent"]
      |> Enum.map(fn group ->
        EnvironmentRef.new!(__MODULE__, "codebase-risk:#{group}",
          label: "#{group} source group",
          metadata: %{
            source_kind: :code,
            fixture_id: "lambda_codebase_risk_inventory",
            group: group
          }
        )
      end)

    contracts =
      Enum.map(refs, fn ref ->
        ContextSliceContract.new!(ref,
          id: "context-slice:#{ref.source_id}",
          source_kind: :code,
          token_budget: 3_000,
          expected_output_schema: %{type: :risk_inventory_item, required: [:risk, :files]},
          merge_policy: %{reducer: :merge_risk_inventory, group_by: :risk_kind},
          review_policy: %{checks: [:coverage, :file_provenance]},
          metadata: %{fixture_id: "lambda_codebase_risk_inventory"}
        )
      end)

    policy =
      Policy.new!(
        leaf_window: 3_000,
        max_depth: 2,
        max_branching_factor: 4,
        max_leaf_calls: 8,
        max_reduce_calls: 1,
        max_environment_reads: 4,
        concurrency: 4,
        allowed_combinators: [:split, :map, :filter, :reduce, :review, :generate],
        review_policy: %{required?: true, provenance_required?: true},
        metadata: %{fixture_id: "lambda_codebase_risk_inventory"}
      )

    cost_estimate =
      CostEstimate.new!(
        leaf_calls: 8,
        filter_calls: 1,
        reducer_calls: 1,
        environment_reads: 4,
        input_tokens: 24_000,
        output_tokens: 3_200,
        latency_class: :bounded_parallel,
        confidence: 0.82,
        assumptions: ["four source groups, two leaf chunks per group"],
        metadata: %{fixture_id: "lambda_codebase_risk_inventory"}
      )

    LambdaPlan.new!(
      "Produce a codebase risk inventory from grouped source bundles",
      :codebase_qa,
      refs,
      id: "lambda-plan:codebase-risk-inventory",
      operators: [
        %{op: :split, by: :source_group, target_tokens: 3_000},
        %{op: :map, component: :llm_extract, schema: :risk_inventory_item},
        %{op: :filter, predicate: :has_file_evidence},
        %{op: :reduce, reducer: :merge_risk_inventory},
        %{op: :review, checks: [:coverage, :file_provenance]},
        %{op: :generate, component: :report_composer}
      ],
      context_contracts: contracts,
      policy: policy,
      cost_estimate: cost_estimate,
      detection: %{task_shape: :codebase_risk_inventory, structure_known?: true},
      budgets: %{max_leaf_calls: 8, max_depth: 2, max_concurrency: 4},
      estimates: %{leaf_calls: 8, reduce_calls: 1, review_calls: 1, sandbox_executions: 0},
      fallback_strategy: :subagent_delegation,
      metadata: %{fixture_id: "lambda_codebase_risk_inventory"}
    )
  end

  @spec lambda_provenance_reextract_plan() :: LambdaPlan.t()
  def lambda_provenance_reextract_plan do
    source_ref =
      EnvironmentRef.new!(__MODULE__, "deployment-risk-bundle",
        label: "deployment risk bundle",
        metadata: %{source_kind: :document, fixture_id: "lambda_provenance_reextract"}
      )

    contract =
      ContextSliceContract.new!(source_ref,
        id: "context-slice:deployment-risk-bundle",
        source_kind: :document,
        token_budget: 3_500,
        expected_output_schema: %{
          type: :deployment_risk,
          required: [:claim, :severity, :evidence_refs]
        },
        merge_policy: %{reducer: :merge_claims, retain_missing_provenance?: true},
        review_policy: %{checks: [:coverage, :provenance], repair: :targeted_reextract},
        metadata: %{fixture_id: "lambda_provenance_reextract"}
      )

    policy =
      Policy.new!(
        leaf_window: 3_500,
        max_depth: 2,
        max_branching_factor: 3,
        max_leaf_calls: 7,
        max_reduce_calls: 1,
        max_environment_reads: 4,
        max_plan_patches: 1,
        concurrency: 3,
        allowed_combinators: [:split, :map, :filter, :reduce, :review, :generate],
        review_policy: %{required?: true, repair_strategy: :targeted_reextract},
        metadata: %{fixture_id: "lambda_provenance_reextract"}
      )

    cost_estimate =
      CostEstimate.new!(
        leaf_calls: 7,
        filter_calls: 1,
        reducer_calls: 1,
        environment_reads: 4,
        plan_patches: 1,
        input_tokens: 22_000,
        output_tokens: 3_800,
        latency_class: :bounded_repair,
        confidence: 0.78,
        assumptions: ["one missing-provenance review failure triggers one targeted re-extraction"],
        metadata: %{fixture_id: "lambda_provenance_reextract"}
      )

    LambdaPlan.new!(
      "Extract deployment risks, review provenance, and re-extract missing evidence",
      :extraction,
      [source_ref],
      id: "lambda-plan:provenance-reextract",
      operators: [
        %{op: :split, by: :section, target_tokens: 3_500},
        %{op: :map, component: :llm_extract, schema: :deployment_risk},
        %{op: :filter, predicate: :has_evidence_or_needs_repair},
        %{op: :reduce, reducer: :merge_claims},
        %{op: :review, checks: [:provenance], on_failure: :targeted_reextract},
        %{op: :map, component: :llm_extract, mode: :targeted_reextract},
        %{op: :generate, component: :report_composer}
      ],
      context_contracts: [contract],
      policy: policy,
      cost_estimate: cost_estimate,
      detection: %{
        task_shape: :extraction_with_review_repair,
        structure_known?: true,
        expected_repair: :targeted_reextract
      },
      budgets: %{max_leaf_calls: 7, max_depth: 2, max_concurrency: 3, max_plan_patches: 1},
      estimates: %{leaf_calls: 7, reduce_calls: 1, review_calls: 1, sandbox_executions: 0},
      fallback_strategy: :subagent_delegation,
      metadata: %{
        fixture_id: "lambda_provenance_reextract",
        repair_trigger: :missing_provenance
      }
    )
  end

  @spec subagent_file_group_assignments() :: [SubagentAssignment.t()]
  def subagent_file_group_assignments do
    ["web", "runtime", "sandbox"]
    |> Enum.map(fn group ->
      SubagentAssignment.new!(
        id: "subagent:#{group}:review",
        role: "#{group} reviewer",
        objective: "Review #{group} files for sandbox/RLM integration risks",
        prompt: "Return claims with evidence refs, confidence, and reviewer_notes.",
        strategy: :subagent_delegation,
        agent_kind: :standard,
        context_slice: %{
          id: "slice:#{group}",
          source_kind: :code,
          file_group: group,
          max_files: 12
        },
        capability_profile: :local_workbench,
        visible_tools: ["find_files", "read_many", "report"],
        budgets: %{max_tool_calls: 12, max_turns: 4},
        output_schema: %{
          claims: [%{claim: :string, evidence_refs: [:string], reviewer_notes: :string}]
        },
        review_policy: %{reducer: :claim_agreement, require_evidence?: true},
        parent: %{
          run_id: "fixture:subagent_file_group_review",
          strategy: :subagent_delegation,
          depth: 0,
          fallback: :lambda_workflow,
          remaining_budgets: %{max_subagents: 3, max_review_passes: 1}
        },
        metadata: %{fixture_id: "subagent_file_group_review", file_group: group}
      )
    end)
  end

  @spec large_context_repl_state() :: State.t()
  def large_context_repl_state do
    context_ref =
      EnvironmentRef.new!(__MODULE__, "unknown-schema-jsonl",
        label: "unknown JSONL export",
        metadata: %{source_kind: :artifact, fixture_id: "repl_unknown_schema"}
      )

    State.new!("sandbox-session:repl-unknown-schema",
      id: "repl-state:unknown-schema",
      runtime: :python,
      context_ref: context_ref,
      variables: %{
        "context" => %{
          kind: :artifact_ref,
          value: EnvironmentRef.key(context_ref),
          metadata: %{symbolic?: true}
        },
        "schema_guess" => %{
          kind: :value,
          value: nil,
          metadata: %{status: :unknown}
        }
      },
      observations: [
        %{id: "observation:1", kind: :stdout_preview, bytes: 512, summary: "sampled 20 rows"}
      ],
      budgets: %{
        llm_query: %{limit: 4, used: 1, max_batch_size: 2},
        delegate: %{limit: 2, used: 0},
        sandbox_exec: %{limit: 6, used: 2}
      },
      checkpoints: [%{id: "checkpoint:before-schema-probe", reason: :before_exploration}],
      metadata: %{fixture_id: "repl_unknown_schema", symbolic_context?: true}
    )
  end

  @spec context_discovery_repl_state() :: State.t()
  def context_discovery_repl_state do
    context_ref =
      EnvironmentRef.new!(__MODULE__, "mixed-workspace-context",
        label: "mixed workspace context",
        metadata: %{source_kind: :workspace_selection, fixture_id: "repl_context_discovery"}
      )

    State.new!("sandbox-session:repl-context-discovery",
      id: "repl-state:context-discovery",
      runtime: :python,
      context_ref: context_ref,
      variables: %{
        "context" => %{
          kind: :workspace_selection_ref,
          value: EnvironmentRef.key(context_ref),
          metadata: %{symbolic?: true, loaded_bytes: 0}
        },
        "helper_code" => %{
          kind: :sandbox_file,
          value: "tools/discover_slices.py",
          metadata: %{purpose: :index_search_transform}
        },
        "discovered_slices" => %{
          kind: :value,
          value: ["auth/*.ex", "billing/*.ex", "mailers/*.ex"],
          metadata: %{source: :helper_code}
        }
      },
      observations: [
        %{id: "observation:1", kind: :helper_summary, summary: "indexed 64 files"},
        %{id: "observation:2", kind: :delegate_summary, summary: "billing slice needs reviewer"}
      ],
      budgets: %{
        llm_query: %{limit: 5, used: 2, max_batch_size: 2},
        delegate: %{limit: 3, used: 1},
        sandbox_exec: %{limit: 8, used: 3}
      },
      checkpoints: [
        %{id: "checkpoint:before-helper-code", reason: :before_helper_write},
        %{id: "checkpoint:after-discovery", reason: :after_slice_discovery}
      ],
      metadata: %{
        fixture_id: "repl_context_discovery",
        symbolic_context?: true,
        helper_code?: true,
        mediated_subcalls?: true,
        resume_after_checkpoint?: true
      }
    )
  end

  @spec denied_generated_component_promotion() :: map()
  def denied_generated_component_promotion do
    component =
      GeneratedComponent.new!(
        id: "generated-component:risky-csv-normalizer",
        name: "RiskyCsvNormalizer",
        language: :python,
        runtime: :python,
        entrypoint: "normalize.run",
        capability_profile: :local_workbench,
        sandbox_profile: :local_code,
        source_artifacts: [%{path: "normalize.py", sha256: "fixture-source"}],
        test_artifacts: [%{path: "test_normalize.py", sha256: "fixture-test"}],
        interface: %{
          input_schema: %{type: :csv},
          output_schema: %{type: :json_records}
        },
        verification: %{status: :pass, tests: 3, sandbox_backend: :just_bash},
        promotion_status: :verified,
        metadata: %{
          fixture_id: "generated_component_promotion_denied",
          policy: %{network: :disabled, filesystem: :sandbox_only}
        }
      )

    {:ok, decision} =
      GeneratedComponentPromotionPolicy.evaluate(component,
        target: :host_repo,
        resume_key: "review:fixture:generated_component_promotion_denied"
      )

    review_decision =
      ReviewDecision.new!(decision.review_request.resume_key, :rejected,
        actor: "fixture-reviewer",
        metadata: %{reason: :insufficient_contract_evidence}
      )

    {:ok, rejected_component} =
      GeneratedComponentPromotionPolicy.apply_decision(component, decision,
        review_decision: review_decision
      )

    %{
      component: component,
      decision: decision,
      review_decision: review_decision,
      rejected_component: rejected_component
    }
  end

  @spec generated_component_promotion_flywheel_fixture() :: map()
  def generated_component_promotion_flywheel_fixture do
    objective_a = "Normalize semi-structured invoice rows into invoice facts"
    objective_b = "Parse new invoice rows into normalized invoice facts"

    component =
      GeneratedComponent.new!(
        id: "generated-component:invoice-row-normalizer",
        name: "InvoiceRowNormalizer",
        language: :python,
        runtime: :python,
        entrypoint: "component.py:run",
        capability_profile: :local_workbench,
        sandbox_profile: :local_code,
        source_artifacts: [%{path: "component.py", sha256: "fixture-invoice-source"}],
        test_artifacts: [%{path: "test_component.py", sha256: "fixture-invoice-test"}],
        interface: %{
          inputs: [%{name: "rows", type: "list<object>"}],
          outputs: [%{name: "invoice_facts", type: "list<object>"}],
          examples: [
            %{
              input_ref: "fixtures/invoice_rows_a.json",
              output_ref: "fixtures/invoice_facts_a.json"
            }
          ]
        },
        verification: %{
          status: :pass,
          command: "python -m pytest",
          tests: 4,
          sandbox_backend: :just_bash
        },
        promotion_status: :verified,
        metadata: %{
          fixture_id: "generated_component_promotion_flywheel",
          intent_tags: [:parse, :normalize, :tabular],
          network: :disabled,
          policy: %{network: :disabled, filesystem: :sandbox_only}
        }
      )

    gap =
      GeneratedComponentCatalog.capability_gap!(
        id: "gap:invoice-row-normalizer",
        objective: objective_a,
        required_contract: %{
          intent_tags: [:parse, :normalize, :tabular],
          inputs: [%{name: "rows", type: "list<object>"}],
          outputs: [%{name: "invoice_facts", type: "list<object>"}],
          runtime: :python,
          policy: %{network: :disabled}
        },
        candidates: [],
        selected_action: :generate_leaf,
        selected_component_id: nil,
        reason: "no existing catalog entry normalizes invoice rows with this output contract"
      )

    {:ok, entry} =
      GeneratedComponentCatalog.entry_from_component(component,
        promotion_decision: %{
          action: :promote,
          reason: :component_promotable,
          details: %{target: :artifact}
        }
      )

    {:ok, store_after_promotion} = GeneratedComponentCatalog.new_store(entries: [entry])

    {:ok, [catalog_hit | _rest]} =
      GeneratedComponentCatalog.search(store_after_promotion,
        objective: objective_b,
        intent_tags: [:parse, :normalize, :tabular],
        inputs: [%{name: "rows"}],
        outputs: [%{name: "invoice_facts"}],
        component_kind: :sandbox_execute,
        runtime: :python,
        policy: %{network: :disabled}
      )

    {:ok, store_after_reuse} =
      GeneratedComponentCatalog.record_reuse(
        store_after_promotion,
        entry.id,
        :success,
        used_at: ~U[2026-05-31 14:00:00Z],
        objective: objective_b,
        workflow_id: "workflow:invoice-row-normalizer-reuse"
      )

    {:ok, reused_entry} = GeneratedComponentCatalog.get(store_after_reuse, entry.id)

    %{
      run_a: %{
        objective: objective_a,
        decision: :generate_leaf,
        capability_gap: gap,
        proof_status: :pass,
        promotion_target: :artifact,
        catalog_entry_id: entry.id
      },
      run_b: %{
        objective: objective_b,
        decision: :reuse_exact,
        catalog_entry_id: catalog_hit.entry.id,
        catalog_score: catalog_hit.score,
        match_reasons: catalog_hit.reasons,
        workflow_completed?: true
      },
      catalog_entry: entry,
      reused_entry: reused_entry,
      summary: %{
        runs: 2,
        generated_components: 1,
        promoted_components: 1,
        catalog_hits: 1,
        reused_components: 1,
        proof_pass_rate: 1.0,
        reuse_rate: 0.5,
        repair_count: 0,
        workflow_completion_rate: 1.0,
        host_mutations_avoided: 2
      }
    }
  end

  defp bad_sandbox_code_repair do
    scenario(
      "bad_sandbox_code_repair",
      "Bad Sandbox Code Repair",
      "Build a reusable parser component for malformed CSV exports and repair failing sandbox tests",
      :generated_sandbox_component,
      %{repeated_transform?: true, input_paths: ["fixtures/bad.csv"]},
      fixtures: %{
        failing_source: "def parse(row): return row.split(',')[2]",
        repair_signal: %{exit_status: 1, stderr: "IndexError: list index out of range"},
        expected_repair: :guard_missing_columns
      },
      evidence_requirements: [:sandbox_exec_diagnostics, :repair_attempt, :passing_tests],
      harness_specs:
        harness_specs(:generated_sandbox_component,
          planned: metric(model_calls: 2, sandbox_calls: 4, review_pauses: 1),
          actual: metric(model_calls: 2, sandbox_calls: 4, review_pauses: 1),
          quality: quality(0.82, "repair guard added and tests pass")
        )
    )
  end

  defp lambda_report_generation do
    scenario(
      "lambda_report_generation",
      "Lambda Report Generation",
      "Extract risks from source bundle sections and write a reviewed report",
      :lambda_workflow,
      %{large_context?: true, input_paths: ["sources/a.md", "sources/b.md", "sources/c.md"]},
      fixtures: %{lambda_plan: lambda_report_plan()},
      evidence_requirements: [:lambda_plan, :planned_call_count, :review_contract],
      harness_specs:
        harness_specs(:lambda_workflow,
          planned: metric(model_calls: 8, sandbox_calls: 0, fan_out: 6, review_pauses: 1),
          actual: metric(model_calls: 8, sandbox_calls: 0, fan_out: 6, review_pauses: 1),
          quality: quality(0.88, "planned call count matches actual")
        )
    )
  end

  defp lambda_codebase_risk_inventory do
    scenario(
      "lambda_codebase_risk_inventory",
      "Lambda Codebase Risk Inventory",
      "Produce a codebase risk inventory from grouped source bundles",
      :lambda_workflow,
      %{
        large_context?: true,
        input_paths: ["lib/web", "lib/runtime", "lib/sandbox", "lib/agent"]
      },
      fixtures: %{lambda_plan: lambda_codebase_risk_plan()},
      evidence_requirements: [
        :known_structure,
        :codebase_risk_inventory,
        :file_group_context_contracts,
        :planned_call_count
      ],
      harness_specs:
        harness_specs(:lambda_workflow,
          planned:
            metric(
              model_calls: 10,
              sandbox_calls: 0,
              fan_out: 8,
              review_pauses: 1,
              cost_estimate: 10,
              context_root_tokens: 1_200,
              context_leaf_tokens: 24_000
            ),
          actual:
            metric(
              model_calls: 10,
              sandbox_calls: 0,
              fan_out: 8,
              review_pauses: 1,
              cost_estimate: 10,
              context_root_tokens: 1_200,
              context_leaf_tokens: 24_000
            ),
          quality: quality(0.84, "risk inventory structure and call estimate are known")
        )
    )
  end

  defp lambda_provenance_reextract do
    scenario(
      "lambda_provenance_reextract",
      "Lambda Provenance Re-Extraction",
      "Extract deployment risks, review provenance, and re-extract missing evidence",
      :lambda_workflow,
      %{large_context?: true, input_paths: ["deployment/a.md", "deployment/b.md"]},
      fixtures: %{
        lambda_plan: lambda_provenance_reextract_plan(),
        review_failure: %{reason: :missing_provenance, affected_slice: "deployment-risk-bundle:2"},
        targeted_reextract: %{slice: "deployment-risk-bundle:2", expected_new_evidence_refs: 2}
      },
      evidence_requirements: [
        :known_structure,
        :provenance_review,
        :targeted_reextract,
        :planned_call_count
      ],
      harness_specs:
        harness_specs(:lambda_workflow,
          planned:
            metric(
              model_calls: 9,
              sandbox_calls: 0,
              fan_out: 7,
              retries: 1,
              review_pauses: 1,
              cost_estimate: 9,
              context_root_tokens: 1_000,
              context_leaf_tokens: 22_000
            ),
          actual:
            metric(
              model_calls: 9,
              sandbox_calls: 0,
              fan_out: 7,
              retries: 1,
              review_pauses: 1,
              cost_estimate: 9,
              context_root_tokens: 1_000,
              context_leaf_tokens: 22_000
            ),
          quality: quality(0.81, "missing provenance triggers targeted re-extraction")
        )
    )
  end

  defp subagent_file_group_review do
    scenario(
      "subagent_file_group_review",
      "Subagent File Group Review",
      "Delegate by file group and reconcile reviewer findings for sandbox integration risks",
      :subagent_delegation,
      %{delegate?: true, input_paths: Enum.map(1..12, &"lib/group_#{&1}.ex")},
      fixtures: %{assignments: subagent_file_group_assignments()},
      evidence_requirements: [:subagent_assignments, :reducer_claims, :reviewer_notes],
      harness_specs:
        harness_specs(:subagent_delegation,
          planned: metric(model_calls: 4, sandbox_calls: 0, fan_out: 3, review_pauses: 1),
          actual: metric(model_calls: 4, sandbox_calls: 0, fan_out: 3, review_pauses: 1),
          quality: quality(0.8, "three file-group claims reduced with notes")
        )
    )
  end

  defp repl_unknown_schema do
    scenario(
      "repl_unknown_schema",
      "Unknown Schema REPL Exploration",
      "Explore this unknown schema and probe the data interactively before summarizing",
      :sandbox_repl,
      %{exploratory?: true, input_paths: ["artifacts/export.jsonl"]},
      fixtures: %{repl_state: large_context_repl_state()},
      evidence_requirements: [:symbolic_context, :bounded_observations, :mediated_subcalls],
      harness_specs:
        harness_specs(:sandbox_repl,
          planned: metric(model_calls: 4, sandbox_calls: 6, fan_out: 2, review_pauses: 0),
          actual: metric(model_calls: 3, sandbox_calls: 5, fan_out: 1, review_pauses: 0),
          quality: quality(0.76, "schema discovered within REPL budgets")
        )
    )
  end

  defp repl_context_discovery do
    scenario(
      "repl_context_discovery",
      "REPL Context Discovery",
      "Explore a large symbolic context, write helper code, delegate one slice, checkpoint, and resume",
      :sandbox_repl,
      %{exploratory?: true, input_paths: ["workspace/context.jsonl"]},
      fixtures: %{
        repl_state: context_discovery_repl_state(),
        helper_code: %{
          path: "tools/discover_slices.py",
          purpose: :index_search_transform,
          operations: [:index_files, :rank_slices, :summarize_candidates]
        },
        resume: %{
          checkpoint_id: "checkpoint:after-discovery",
          summary: "resume with discovered_slices and delegated billing review"
        }
      },
      evidence_requirements: [
        :symbolic_context,
        :helper_code,
        :mediated_subcalls,
        :checkpoint_resume
      ],
      harness_specs:
        harness_specs(:sandbox_repl,
          planned:
            metric(
              model_calls: 5,
              sandbox_calls: 8,
              fan_out: 3,
              review_pauses: 0,
              cost_estimate: 13,
              context_root_bytes: 1_200,
              context_leaf_bytes: 96_000
            ),
          actual:
            metric(
              model_calls: 4,
              sandbox_calls: 7,
              fan_out: 3,
              review_pauses: 0,
              cost_estimate: 11,
              context_root_bytes: 1_200,
              context_leaf_bytes: 92_000
            ),
          quality: quality(0.77, "REPL discovered slices with helper code and bounded delegation")
        )
    )
  end

  defp generated_component_promotion_denied do
    scenario(
      "generated_component_promotion_denied",
      "Generated Component Promotion Denied",
      "Generate a component and request host repo promotion, then deny promotion by review",
      :generated_sandbox_component,
      %{repeated_transform?: true},
      fixtures: denied_generated_component_promotion(),
      evidence_requirements: [:verified_component, :promotion_review, :rejected_review_decision],
      harness_specs:
        harness_specs(:generated_sandbox_component,
          planned: metric(model_calls: 1, sandbox_calls: 2, review_pauses: 1),
          actual: metric(model_calls: 1, sandbox_calls: 2, review_pauses: 1),
          quality: quality(0.7, "component verified but host promotion rejected")
        )
    )
  end

  defp generated_component_promotion_flywheel do
    fixtures = generated_component_promotion_flywheel_fixture()

    planned =
      metric(model_calls: 2, sandbox_calls: 3, review_pauses: 0, host_mutations_avoided: 2)
      |> Map.merge(%{
        generated_components: 1,
        promoted_components: 1,
        catalog_hits: 1,
        reused_components: 1,
        proof_pass_rate: 1.0,
        reuse_rate: 0.5,
        repair_count: 0,
        workflow_completion_rate: 1.0
      })

    actual =
      metric(model_calls: 2, sandbox_calls: 3, review_pauses: 0, host_mutations_avoided: 2)
      |> Map.merge(fixtures.summary)
      |> Map.put(:promotion_decisions, %{artifact: 1, host_repo: 0, rejected: 0})

    scenario(
      "generated_component_promotion_flywheel",
      "Generated Component Promotion Flywheel",
      "Generate, prove, promote, retrieve, and reuse a sandbox-backed invoice normalizer",
      :generated_sandbox_component,
      %{repeated_transform?: true, generated_component_catalog?: true},
      fixtures: fixtures,
      evidence_requirements: [
        :capability_gap,
        :sandbox_proof,
        :catalog_write,
        :catalog_reuse,
        :salience_update
      ],
      harness_specs:
        harness_specs(:generated_sandbox_component,
          planned: planned,
          actual: actual,
          quality: quality(0.88, "second run reused the promoted component without repair")
        )
    )
  end

  defp sandbox_proxy_service_smoke do
    scenario(
      "sandbox_proxy_service_smoke",
      "Sandbox Proxy Service Smoke",
      "Start a sandbox service through a proxy and smoke test the health endpoint",
      :sandbox_repl,
      %{exploratory?: true, service_smoke?: true},
      fixtures: %{
        service: %{
          start_tool: "start_sandbox_service",
          proxy_tool: "open_sandbox_proxy",
          smoke_request: %{method: "GET", path: "/health"},
          expected_status: 200,
          review_required?: true
        }
      },
      evidence_requirements: [:service_id, :proxy_id, :health_check, :review_gate],
      harness_specs:
        harness_specs(:sandbox_repl,
          planned: metric(model_calls: 1, sandbox_calls: 3, review_pauses: 1),
          actual: metric(model_calls: 1, sandbox_calls: 3, review_pauses: 1),
          quality: quality(0.74, "service health is observable through proxy")
        )
    )
  end

  defp checkpoint_restore_after_failure do
    repl_state =
      large_context_repl_state()
      |> State.add_checkpoint(%{id: "checkpoint:after-failed-probe", reason: :failed_probe})
      |> case do
        {:ok, state} -> state
        {:error, error} -> raise ArgumentError, error.message
      end

    scenario(
      "checkpoint_restore_after_failure",
      "Checkpoint Restore After Failure",
      "Checkpoint sandbox state, run a failing probe, restore, and continue with a safer query",
      :sandbox_repl,
      %{exploratory?: true, input_paths: ["artifacts/export.jsonl"]},
      fixtures: %{
        repl_state: repl_state,
        failing_probe: %{exit_status: 1, stderr: "KeyError: customer_id"},
        restore_checkpoint_id: "checkpoint:before-schema-probe"
      },
      evidence_requirements: [:checkpoint_id, :failed_attempt, :restore_event, :continued_result],
      harness_specs:
        harness_specs(:sandbox_repl,
          planned: metric(model_calls: 3, sandbox_calls: 5, review_pauses: 0),
          actual: metric(model_calls: 3, sandbox_calls: 6, review_pauses: 0),
          quality: quality(0.72, "restore allowed safer query after failure")
        )
    )
  end

  defp strategy_family_report do
    specs =
      @comparison_harnesses
      |> Map.new(fn
        :direct_standard_agent ->
          {:direct_standard_agent,
           harness_spec(:direct_standard_agent,
             strategy: :direct_standard_agent,
             planned: metric(model_calls: 1, sandbox_calls: 0, fan_out: 1),
             actual: metric(model_calls: 1, sandbox_calls: 0, fan_out: 1),
             quality: quality(0.46, "root context too narrow for full report")
           )}

        :dynamic_workflow_coordinator ->
          {:dynamic_workflow_coordinator,
           harness_spec(:dynamic_workflow_coordinator,
             strategy: :host_edit_workflow,
             planned: metric(model_calls: 3, sandbox_calls: 1, fan_out: 1),
             actual: metric(model_calls: 5, sandbox_calls: 1, fan_out: 1, retries: 2),
             quality: quality(0.58, "graph repair consumed extra calls")
           )}

        :lambda_workflow ->
          {:lambda_workflow,
           harness_spec(:lambda_workflow,
             strategy: :lambda_workflow,
             planned: metric(model_calls: 8, sandbox_calls: 0, fan_out: 6, review_pauses: 1),
             actual: metric(model_calls: 8, sandbox_calls: 0, fan_out: 6, review_pauses: 1),
             quality: quality(0.88, "structure known before execution")
           )}

        :subagent_delegation ->
          {:subagent_delegation,
           harness_spec(:subagent_delegation,
             strategy: :subagent_delegation,
             planned: metric(model_calls: 4, sandbox_calls: 0, fan_out: 3, review_pauses: 1),
             actual: metric(model_calls: 4, sandbox_calls: 0, fan_out: 3, review_pauses: 1),
             quality: quality(0.8, "independent reviewers preserve evidence")
           )}

        :sandbox_repl ->
          {:sandbox_repl,
           harness_spec(:sandbox_repl,
             strategy: :sandbox_repl,
             planned: metric(model_calls: 4, sandbox_calls: 5, fan_out: 2),
             actual: metric(model_calls: 4, sandbox_calls: 5, fan_out: 2),
             quality: quality(0.73, "useful but more exploratory than required")
           )}

        :generated_sandbox_component ->
          {:generated_sandbox_component,
           harness_spec(:generated_sandbox_component,
             strategy: :generated_sandbox_component,
             planned: metric(model_calls: 2, sandbox_calls: 4, review_pauses: 1),
             actual: metric(model_calls: 2, sandbox_calls: 4, review_pauses: 1),
             quality: quality(0.69, "component useful for repeated extraction only")
           )}
      end)

    scenario(
      "strategy_family_report",
      "Strategy Family Report Comparison",
      "Extract, compare, and report risks from several source bundles",
      :lambda_workflow,
      %{large_context?: true, input_paths: ["bundle/a.md", "bundle/b.md", "bundle/c.md"]},
      fixtures: %{
        lambda_plan: lambda_report_plan(),
        assignments: subagent_file_group_assignments()
      },
      comparison_harnesses: @comparison_harnesses,
      evidence_requirements: [:router_decision, :planned_vs_actual, :artifact_quality],
      harness_specs: specs
    )
  end

  defp scenario(id, title, objective, expected_strategy, router_opts, opts) do
    harness_specs = Keyword.fetch!(opts, :harness_specs)

    %{
      id: id,
      title: title,
      objective: objective,
      expected_strategy: expected_strategy,
      router_opts: router_opts,
      fixtures: Keyword.get(opts, :fixtures, %{}),
      comparison_harnesses: Keyword.get(opts, :comparison_harnesses, [expected_strategy]),
      harness_specs: harness_specs,
      evidence_requirements: Keyword.get(opts, :evidence_requirements, []),
      metadata: %{
        deterministic?: true,
        live_backend_required?: false,
        fixture_version: 1
      }
    }
  end

  defp harness_specs(strategy, opts) do
    %{strategy => harness_spec(strategy, opts)}
  end

  defp harness_spec(harness, opts) do
    %{
      strategy: Keyword.get(opts, :strategy, harness),
      planned: Keyword.fetch!(opts, :planned),
      actual: Keyword.fetch!(opts, :actual),
      quality: Keyword.fetch!(opts, :quality),
      review_notes: Keyword.get(opts, :review_notes, []),
      artifact_refs: Keyword.get(opts, :artifact_refs, [])
    }
  end

  defp metric(opts) do
    %{
      success?: Keyword.get(opts, :success?, true),
      model_calls: Keyword.get(opts, :model_calls, 0),
      sandbox_calls: Keyword.get(opts, :sandbox_calls, 0),
      fan_out: Keyword.get(opts, :fan_out, 1),
      retries: Keyword.get(opts, :retries, 0),
      review_pauses: Keyword.get(opts, :review_pauses, 0),
      latency_ms: Keyword.get(opts, :latency_ms, 0),
      host_mutations_avoided: Keyword.get(opts, :host_mutations_avoided, 0),
      cost_estimate: Keyword.get(opts, :cost_estimate, 0),
      context_root_bytes: Keyword.get(opts, :context_root_bytes, 0),
      context_leaf_bytes: Keyword.get(opts, :context_leaf_bytes, 0),
      context_root_tokens: Keyword.get(opts, :context_root_tokens, 0),
      context_leaf_tokens: Keyword.get(opts, :context_leaf_tokens, 0)
    }
  end

  defp quality(score, note) do
    %{score: score, status: quality_status(score), note: note}
  end

  defp quality_status(score) when score >= 0.8, do: :passing
  defp quality_status(score) when score >= 0.65, do: :usable
  defp quality_status(_score), do: :failing

  defp scenario!(%{} = scenario), do: scenario
  defp scenario!(id), do: get!(id)

  defp router_summary(%StrategyRouter{} = decision) do
    %{
      strategy: decision.strategy,
      confidence: decision.confidence,
      fallback: decision.fallback,
      reasons: decision.reasons,
      budgets: decision.budgets,
      metadata: decision.metadata
    }
  end

  defp metric_deltas(planned, actual) do
    planned
    |> Map.keys()
    |> Kernel.++(Map.keys(actual))
    |> Enum.uniq()
    |> Enum.filter(
      &(numeric_metric?(Map.get(planned, &1)) or numeric_metric?(Map.get(actual, &1)))
    )
    |> Map.new(fn key -> {key, numeric_metric(actual[key]) - numeric_metric(planned[key])} end)
  end

  defp numeric_metric?(value), do: is_integer(value) or is_float(value)

  defp numeric_metric(value) when is_integer(value) or is_float(value), do: value
  defp numeric_metric(_value), do: 0

  defp strategy_changed?(strategy, actual) do
    case Map.get(actual, :strategy) || Map.get(actual, "strategy") do
      nil -> false
      ^strategy -> false
      _other -> true
    end
  end

  defp evaluation_case(scenario, record) do
    Case.new!(
      id: "#{scenario.id}:#{record.harness}",
      input: %{
        objective: scenario.objective,
        fixture_id: scenario.id,
        harness: record.harness,
        router_decision: record.router_decision
      },
      expected: [
        {:custom,
         fn %Result{} = result ->
           %{
             passed?: result.metrics.success? and result.scores.overall >= 0.65,
             score: result.scores.overall,
             message: result.metadata.quality.note
           }
         end}
      ],
      tags: ["sandbox", "rlm", "phase8", Atom.to_string(record.harness)],
      metadata: %{
        fixture_id: scenario.id,
        harness: record.harness,
        strategy: record.strategy,
        expected_strategy: scenario.expected_strategy,
        evidence_requirements: scenario.evidence_requirements
      }
    )
  end

  defp evaluation_result(scenario, record) do
    status =
      if record.actual.success? and record.quality.score >= 0.65, do: :passed, else: :failed

    Result.new!(
      "#{scenario.id}:#{record.harness}",
      status: status,
      outputs: [
        %{
          fixture_id: scenario.id,
          harness: record.harness,
          strategy: record.strategy,
          router_decision: record.router_decision,
          planned: record.planned,
          actual: record.actual,
          deltas: record.deltas,
          quality: record.quality,
          review_notes: record.review_notes,
          artifact_refs: record.artifact_refs
        }
      ],
      scores: %{
        overall: record.quality.score,
        quality_status: record.quality.status
      },
      metrics:
        Map.merge(record.actual, %{
          planned: record.planned,
          deltas: record.deltas,
          strategy_changed?: record.strategy_changed?,
          planned_model_calls: record.planned.model_calls,
          planned_sandbox_calls: record.planned.sandbox_calls,
          planned_cost_estimate: record.planned.cost_estimate,
          actual_cost_estimate: record.actual.cost_estimate
        }),
      failures: failures(record),
      metadata: %{
        fixture_id: scenario.id,
        harness: record.harness,
        strategy: record.strategy,
        router_decision: record.router_decision,
        quality: record.quality,
        review_notes: record.review_notes,
        artifact_refs: record.artifact_refs
      }
    )
  end

  defp failures(record) do
    cond do
      not record.actual.success? ->
        [%{reason: :fixture_marked_unsuccessful, details: record.actual}]

      record.quality.score < 0.65 ->
        [%{reason: :quality_below_threshold, details: record.quality}]

      true ->
        []
    end
  end

  defp aggregate(records) do
    count = length(records)
    passed = Enum.count(records, &(&1.actual.success? and &1.quality.score >= 0.65))
    failed = count - passed

    %{
      cases: count,
      passed: passed,
      failed: failed,
      success_rate: ratio(passed, count),
      average_quality: average(Enum.map(records, & &1.quality.score)),
      model_calls: sum_metric(records, :model_calls),
      sandbox_calls: sum_metric(records, :sandbox_calls),
      retries: sum_metric(records, :retries),
      review_pauses: sum_metric(records, :review_pauses),
      latency_ms: sum_metric(records, :latency_ms),
      planned_model_calls: sum_planned_metric(records, :model_calls),
      planned_sandbox_calls: sum_planned_metric(records, :sandbox_calls),
      planned_cost_estimate: sum_planned_metric(records, :cost_estimate),
      actual_cost_estimate: sum_metric(records, :cost_estimate),
      context_root_bytes: sum_metric(records, :context_root_bytes),
      context_leaf_bytes: sum_metric(records, :context_leaf_bytes),
      context_root_tokens: sum_metric(records, :context_root_tokens),
      context_leaf_tokens: sum_metric(records, :context_leaf_tokens),
      strategy_changes: Enum.count(records, & &1.strategy_changed?),
      host_mutations_avoided: sum_metric(records, :host_mutations_avoided)
    }
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp sum_metric(records, key),
    do: Enum.reduce(records, 0, &(&2 + numeric_metric(&1.actual[key])))

  defp sum_planned_metric(records, key),
    do: Enum.reduce(records, 0, &(&2 + numeric_metric(&1.planned[key])))

  defp score(%Result{} = result), do: result.scores.overall

  defp expectation_payload(expectation) do
    expectation
    |> Map.from_struct()
    |> Map.update!(:target, &inspect_target/1)
  end

  defp inspect_target(target) when is_function(target), do: inspect(target)
  defp inspect_target(target), do: target

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
