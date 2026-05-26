defmodule RunicAI.RLM.SandboxEvaluationFixturesTest do
  use ExUnit.Case, async: true

  alias RunicAI.RLM.LambdaPlan
  alias RunicAI.RLM.SandboxEvaluationFixtures
  alias RunicAI.RLM.SubagentAssignment
  alias RunicAI.Sandbox.GeneratedComponent

  test "fixtures are deterministic and route to their expected least-powerful strategies" do
    assert SandboxEvaluationFixtures.scenario_ids() == [
             "bad_sandbox_code_repair",
             "lambda_report_generation",
             "lambda_codebase_risk_inventory",
             "lambda_provenance_reextract",
             "subagent_file_group_review",
             "repl_unknown_schema",
             "repl_context_discovery",
             "generated_component_promotion_denied",
             "sandbox_proxy_service_smoke",
             "checkpoint_restore_after_failure",
             "strategy_family_report"
           ]

    for scenario <- SandboxEvaluationFixtures.scenarios() do
      decision = SandboxEvaluationFixtures.route(scenario)

      assert scenario.metadata.deterministic?
      assert scenario.metadata.live_backend_required? == false
      assert decision.strategy == scenario.expected_strategy
      assert decision.metadata.deterministic?
      assert scenario.evidence_requirements != []
    end
  end

  test "lambda report fixture carries a validated Lambda plan and exact call accounting" do
    scenario = SandboxEvaluationFixtures.get!("lambda_report_generation")

    assert %LambdaPlan{} = plan = scenario.fixtures.lambda_plan
    assert LambdaPlan.operator_names(plan) == [:split, :map, :reduce, :review, :generate]

    assert %{
             matched?: true,
             planned: %{leaf_calls: 6, reduce_calls: 1, review_calls: 1},
             actual: %{leaf_calls: 6, reduce_calls: 1, review_calls: 1}
           } =
             LambdaPlan.call_accounting(plan, %{
               leaf_calls: 6,
               reduce_calls: 1,
               review_calls: 1,
               sandbox_executions: 0
             })

    assert [record] = SandboxEvaluationFixtures.comparison_records(scenario)
    assert record.harness == :lambda_workflow
    assert record.strategy == :lambda_workflow
    assert record.deltas.model_calls == 0
    assert record.quality.status == :passing
  end

  test "Lambda-shaped fixtures cover codebase inventory and provenance repair shapes" do
    inventory = SandboxEvaluationFixtures.get!("lambda_codebase_risk_inventory")
    reextract = SandboxEvaluationFixtures.get!("lambda_provenance_reextract")

    assert SandboxEvaluationFixtures.route(inventory).strategy == :lambda_workflow
    assert SandboxEvaluationFixtures.route(reextract).strategy == :lambda_workflow

    assert %LambdaPlan{} = inventory_plan = inventory.fixtures.lambda_plan

    assert LambdaPlan.operator_names(inventory_plan) == [
             :split,
             :map,
             :filter,
             :reduce,
             :review,
             :generate
           ]

    assert length(inventory_plan.context_contracts) == 4
    assert inventory_plan.detection.structure_known?
    assert inventory_plan.cost_estimate.leaf_calls == 8

    assert %LambdaPlan{} = reextract_plan = reextract.fixtures.lambda_plan

    assert LambdaPlan.operator_names(reextract_plan) == [
             :split,
             :map,
             :filter,
             :reduce,
             :review,
             :map,
             :generate
           ]

    assert reextract_plan.detection.expected_repair == :targeted_reextract
    assert reextract.fixtures.review_failure.reason == :missing_provenance
    assert reextract.fixtures.targeted_reextract.expected_new_evidence_refs == 2

    assert [inventory_record] = SandboxEvaluationFixtures.comparison_records(inventory)
    assert inventory_record.planned.model_calls == inventory_record.actual.model_calls
    assert inventory_record.planned.context_leaf_tokens == 24_000

    assert [reextract_record] = SandboxEvaluationFixtures.comparison_records(reextract)
    assert reextract_record.planned.retries == 1
    assert reextract_record.deltas.model_calls == 0
  end

  test "subagent fixture produces constrained assignments with reducer-ready output schemas" do
    scenario = SandboxEvaluationFixtures.get!("subagent_file_group_review")

    assert [web, runtime, sandbox] = scenario.fixtures.assignments
    assert Enum.all?([web, runtime, sandbox], &match?(%SubagentAssignment{}, &1))

    assert Enum.map([web, runtime, sandbox], & &1.strategy) == [
             :subagent_delegation,
             :subagent_delegation,
             :subagent_delegation
           ]

    assert Enum.map([web, runtime, sandbox], & &1.agent_kind) == [:standard, :standard, :standard]
    assert Enum.all?([web, runtime, sandbox], &("report" in &1.visible_tools))

    assert Enum.all?(
             [web, runtime, sandbox],
             &match?(%{claims: [_claim_shape]}, &1.output_schema)
           )

    assert Enum.all?([web, runtime, sandbox], &(&1.parent.depth == 0))
  end

  test "REPL fixtures carry symbolic context, bounded observations, budgets, and checkpoints" do
    repl = SandboxEvaluationFixtures.get!("repl_unknown_schema").fixtures.repl_state

    assert repl.runtime == :python
    assert repl.context_ref.source_id == "unknown-schema-jsonl"
    assert repl.variables["context"].metadata.symbolic?
    assert repl.observations |> hd() |> Map.fetch!(:summary) == "sampled 20 rows"
    assert repl.budgets.llm_query.limit == 4
    assert repl.budgets.sandbox_exec.used == 2
    assert [%{id: "checkpoint:before-schema-probe"}] = repl.checkpoints

    restored =
      SandboxEvaluationFixtures.get!("checkpoint_restore_after_failure").fixtures.repl_state

    assert Enum.any?(restored.checkpoints, &(&1.id == "checkpoint:after-failed-probe"))
  end

  test "open REPL context discovery fixture carries helper code and mediated subcalls" do
    scenario = SandboxEvaluationFixtures.get!("repl_context_discovery")
    repl = scenario.fixtures.repl_state

    assert SandboxEvaluationFixtures.route(scenario).strategy == :sandbox_repl
    assert repl.variables["helper_code"].value == "tools/discover_slices.py"
    assert repl.variables["discovered_slices"].metadata.source == :helper_code
    assert repl.budgets.delegate.used == 1
    assert repl.metadata.helper_code?
    assert repl.metadata.mediated_subcalls?
    assert repl.metadata.resume_after_checkpoint?
    assert Enum.any?(repl.checkpoints, &(&1.id == "checkpoint:after-discovery"))

    assert scenario.fixtures.helper_code.operations == [
             :index_files,
             :rank_slices,
             :summarize_candidates
           ]

    assert [record] = SandboxEvaluationFixtures.comparison_records(scenario)
    assert record.planned.sandbox_calls == 8
    assert record.actual.sandbox_calls == 7
    assert record.planned.context_leaf_bytes == 96_000
  end

  test "generated component promotion denial fixture records review-gated rejection" do
    scenario = SandboxEvaluationFixtures.get!("generated_component_promotion_denied")
    fixtures = scenario.fixtures

    assert %GeneratedComponent{promotion_status: :verified} = fixtures.component
    assert fixtures.decision.action == :review
    assert fixtures.decision.reason == :host_materialization_requires_review
    assert fixtures.review_decision.status == :rejected
    assert fixtures.rejected_component.promotion_status == :rejected

    assert fixtures.rejected_component.metadata.promotion_rejection.reason ==
             :host_materialization_requires_review
  end

  test "strategy family fixture compares the same objective across harnesses" do
    scenario = SandboxEvaluationFixtures.get!("strategy_family_report")

    assert scenario.comparison_harnesses == SandboxEvaluationFixtures.comparison_harnesses()

    records = SandboxEvaluationFixtures.comparison_records(scenario)

    assert Enum.map(records, & &1.harness) == SandboxEvaluationFixtures.comparison_harnesses()
    assert Enum.find(records, &(&1.harness == :lambda_workflow)).quality.score == 0.88
    assert Enum.find(records, &(&1.harness == :dynamic_workflow_coordinator)).deltas.retries == 2
    assert Enum.all?(records, &(&1.router_decision.strategy == :lambda_workflow))
    assert Enum.all?(records, &is_map(&1.planned))
    assert Enum.all?(records, &is_map(&1.actual))
    assert Enum.all?(records, &Map.has_key?(&1.planned, :success?))
    assert Enum.all?(records, &Map.has_key?(&1.planned, :latency_ms))
    assert Enum.all?(records, &Map.has_key?(&1.planned, :host_mutations_avoided))
  end

  test "comparison records can capture strategy changes from actual metrics" do
    [record] =
      SandboxEvaluationFixtures.comparison_records("repl_unknown_schema", %{
        sandbox_repl: %{
          model_calls: 3,
          sandbox_calls: 5,
          fan_out: 1,
          retries: 0,
          review_pauses: 0,
          latency_ms: 0,
          strategy: :lambda_workflow
        }
      })

    assert record.strategy == :sandbox_repl
    assert record.strategy_changed?
    assert record.actual.strategy == :lambda_workflow
  end

  test "evaluation run persists comparison records as JSON and Markdown artifacts" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "runic-ai-sandbox-eval-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{run: run, json_path: json_path, markdown_path: markdown_path} =
      SandboxEvaluationFixtures.write_evaluation_artifacts!("strategy_family_report", tmp_dir,
        basename: "strategy-family"
      )

    assert %RunicAI.Evaluation.Run{} = run
    assert length(run.cases) == 6
    assert length(run.results) == 6
    assert run.aggregate.cases == 6
    assert run.aggregate.success_rate > 0.0
    assert run.aggregate.model_calls == 24
    assert run.aggregate.sandbox_calls == 10
    assert run.aggregate.review_pauses == 3
    assert run.metadata.router_decision.strategy == :lambda_workflow

    assert File.exists?(json_path)
    assert File.exists?(markdown_path)

    json = json_path |> File.read!() |> Jason.decode!()
    markdown = File.read!(markdown_path)

    assert get_in(json, ["metadata", "router_decision", "fallback"]) == "subagent_delegation"
    assert get_in(json, ["aggregate", "strategy_changes"]) == 0
    assert Enum.all?(json["results"], &Map.has_key?(&1["metrics"], "planned_model_calls"))
    assert Enum.all?(json["results"], &Map.has_key?(&1["metrics"], "planned_cost_estimate"))
    assert markdown =~ "Sandbox/RLM Strategy Evaluation"
    assert markdown =~ "| lambda_workflow | lambda_workflow | passed |"

    %{json_path: lambda_json_path} =
      SandboxEvaluationFixtures.write_evaluation_artifacts!(
        "lambda_codebase_risk_inventory",
        tmp_dir,
        basename: "lambda-codebase"
      )

    lambda_json = lambda_json_path |> File.read!() |> Jason.decode!()
    assert get_in(lambda_json, ["metadata", "fixture_id"]) == "lambda_codebase_risk_inventory"
    assert get_in(lambda_json, ["aggregate", "planned_model_calls"]) == 10
  end
end
