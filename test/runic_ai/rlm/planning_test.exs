defmodule RunicAI.RLM.PlanningTest do
  use ExUnit.Case, async: true

  alias RunicAI.RLM
  alias RunicAI.RLM.Continuation
  alias RunicAI.RLM.ContextSliceContract
  alias RunicAI.RLM.CostEstimate
  alias RunicAI.RLM.Environments.InMemory
  alias RunicAI.RLM.Episode
  alias RunicAI.RLM.LambdaPlan
  alias RunicAI.RLM.PlanNode
  alias RunicAI.RLM.PlanPatch
  alias RunicAI.RLM.Policy
  alias RunicAI.RLM.Probe

  test "default planner creates a bounded split map reduce plan" do
    {:ok, environment} = InMemory.init()

    {:ok, source_ref, _environment} =
      InMemory.put_source(environment, String.duplicate("a", 25), id: "doc")

    policy = Policy.new!(leaf_window: 10, max_depth: 1)
    probe = Probe.new!(source_ref, 25)

    {:ok, plan} = RLM.plan(:summarization, [source_ref], policy: policy, probes: [probe])

    assert Enum.map(plan.nodes, & &1.op) == [:split, :map_leaf, :reduce]
    assert plan.cost_estimate.leaf_calls == 3
    assert plan.cost_estimate.reducer_calls == 1
    assert plan.policy.leaf_window == 10
  end

  test "cost estimates accept string-keyed maps without atomizing input" do
    {:ok, estimate} =
      CostEstimate.from_input(%{
        "leaf_calls" => 2,
        "environment_reads" => 3,
        "latency_class" => :medium,
        "assumptions" => ["probe-based estimate"],
        "metadata" => %{"source" => "planner"}
      })

    assert estimate.leaf_calls == 2
    assert estimate.environment_reads == 3
    assert estimate.latency_class == :medium
    assert estimate.assumptions == ["probe-based estimate"]
    assert estimate.metadata == %{"source" => "planner"}
  end

  test "lambda plans wrap deterministic planner output with contracts and estimates" do
    {:ok, environment} = InMemory.init()

    {:ok, source_ref, _environment} =
      InMemory.put_source(environment, String.duplicate("risk\n", 25), id: "risk-doc")

    policy = Policy.new!(leaf_window: 20, max_depth: 2, concurrency: 4)
    probe = Probe.new!(source_ref, 125, metadata: %{source_kind: :document})

    {:ok, plan} =
      RLM.lambda_plan("extract risks and mitigation actions", :extraction, [source_ref],
        policy: policy,
        probes: [probe]
      )

    assert %LambdaPlan{} = plan
    assert plan.objective == "extract risks and mitigation actions"
    assert plan.task_kind == :extraction
    assert plan.plan.task_kind == :extraction
    assert LambdaPlan.operator_names(plan) == [:split, :filter, :map, :reduce, :review, :generate]
    assert plan.cost_estimate.leaf_calls == 7
    assert plan.estimates.leaf_calls == 7
    assert plan.estimates.reduce_calls == 1
    assert plan.estimates.max_depth == 2
    assert plan.estimates.max_concurrency == 4
    assert plan.detection.decomposition_reason == :deterministic_split_map_reduce
    assert plan.fallback_strategy == :sandbox_repl

    assert [contract] = plan.context_contracts
    assert %ContextSliceContract{} = contract
    assert contract.source_ref.source_id == "risk-doc"
    assert contract.token_budget == 20
    assert contract.expected_output_schema == :extracted_record
    assert contract.merge_policy == :merge_records
    assert contract.review_policy == %{checks: [:coverage, :specificity, :provenance]}
    assert contract.provenance == [source_ref]
  end

  test "context slice contracts preserve explicit bounds schema and policies" do
    source_ref =
      RunicAI.RLM.EnvironmentRef.new!(InMemory, "sandbox-file",
        metadata: %{"source_kind" => "sandbox_file"}
      )

    {:ok, contract} =
      ContextSliceContract.from_input(%{
        "source_ref" => source_ref,
        "slice_id" => "chunk-1",
        "token_budget" => 512,
        "byte_budget" => 4096,
        "expected_output_schema" => %{type: :object, required: [:answer]},
        "merge_policy" => %{strategy: :dedupe_by_source},
        "review_policy" => :coverage_check,
        "metadata" => %{"lane" => "lambda"}
      })

    assert contract.id == "context-slice:sandbox-file"
    assert contract.source_kind == :sandbox_file
    assert contract.slice_id == "chunk-1"
    assert contract.token_budget == 512
    assert contract.byte_budget == 4096
    assert contract.expected_output_schema == %{type: :object, required: [:answer]}
    assert contract.merge_policy == %{strategy: :dedupe_by_source}
    assert contract.review_policy == :coverage_check
    assert contract.metadata == %{"lane" => "lambda"}
  end

  test "lambda plan validation rejects unbounded or unknown control data" do
    {:ok, environment} = InMemory.init()
    {:ok, source_ref, _environment} = InMemory.put_source(environment, "hello", id: "doc")

    assert {:ok, plan} =
             LambdaPlan.new("summarize", :summarization, [source_ref],
               operators: [%{"op" => "split"}],
               fallback_strategy: "sandbox_repl"
             )

    assert LambdaPlan.operator_names(plan) == [:split]
    assert plan.fallback_strategy == :sandbox_repl

    assert {:error, error} =
             LambdaPlan.new("summarize", :summarization, [source_ref],
               operators: [%{op: :unknown}]
             )

    assert error.kind == :validation
    assert error.details.valid_operators == LambdaPlan.operators()

    assert {:error, error} =
             ContextSliceContract.new(source_ref, token_budget: 0, byte_budget: 1)

    assert error.kind == :validation
    assert error.details.field == :token_budget
  end

  test "lambda plans compare planned and actual call counts" do
    {:ok, environment} = InMemory.init()

    {:ok, source_ref, _environment} =
      InMemory.put_source(environment, String.duplicate("summary ", 30), id: "summary-doc")

    policy = Policy.new!(leaf_window: 30, max_depth: 1)
    probe = Probe.new!(source_ref, 240)

    {:ok, plan} =
      RLM.lambda_plan("summarize sections", :summarization, [source_ref],
        policy: policy,
        probes: [probe]
      )

    assert plan.estimates.leaf_calls == 8
    assert plan.estimates.reduce_calls == 1
    assert plan.estimates.review_calls == 1

    assert %{
             matched?: true,
             deltas: %{
               leaf_calls: 0,
               reduce_calls: 0,
               review_calls: 0,
               sandbox_executions: 0
             }
           } =
             LambdaPlan.call_accounting(plan, %{
               lambda_map_calls: 8,
               lambda_reduce_calls: 1,
               lambda_review_calls: 1,
               sandbox_executions: 0
             })

    assert %{
             matched?: false,
             deltas: %{leaf_calls: 1, reduce_calls: 0, review_calls: -1}
           } =
             LambdaPlan.call_accounting(plan, %{
               "lambda_map_calls" => 9,
               "lambda_reduce_calls" => 1,
               "lambda_review_calls" => 0
             })
  end

  test "plan patches and episodes are typed continuation boundaries" do
    patch =
      PlanPatch.new!(
        [PlanNode.new!("inspect-more", :map_leaf, parent_ids: ["reduce"])],
        connect_to: ["reduce"],
        metadata: %{reason: :coverage_gap}
      )

    continuation = Continuation.new!(patch, episode_id: "episode-1")

    episode =
      Episode.new!(:extended, "Need one more focused pass",
        id: "episode-1",
        continuation: continuation
      )

    assert episode.status == :extended
    assert episode.continuation.next == patch
    assert hd(patch.nodes).id == "inspect-more"
  end
end
