defmodule RunicAI.Persistence.WorkflowEvalsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.WorkflowEvals
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.SubstrateEval

  setup do
    {:ok, store} = SQLite.open(":memory:")
    on_exit(fn -> SQLite.close(store) end)
    %{store: store}
  end

  test "persists a JSON DSL operations bake-off with real provider usage fields", %{store: store} do
    {:ok, discover} = Node.new("discover", :source_discovery)

    {:ok, base} =
      IR.new("workflow:substrate-eval", "Evaluate workflow substrates",
        nodes: %{discover.id => discover},
        acceptance: [%{id: "measured", required: true}]
      )

    operations = [%{op: "set_policy", key: "max_runtime_ms", value: 5_000}]

    assert {:ok, edited} =
             Editor.apply(base, %{
               base_revision: base.revision,
               base_hash: IR.semantic_hash(base),
               operations: operations
             })

    provider_usage = %{
      normalized_json: %{input_tokens: 1_200, output_tokens: 700, latency_ms: 900, cost_usd: 0.02},
      compact_dsl: %{input_tokens: 1_000, output_tokens: 420, latency_ms: 820, cost_usd: 0.014},
      typed_operations: %{input_tokens: 600, output_tokens: 80, latency_ms: 500, cost_usd: 0.004}
    }

    assert {:ok, result} =
             SubstrateEval.run_case("repair-policy", edited.ir,
               base_ir: base,
               operations: operations,
               provider_usage: provider_usage
             )

    assert result.all_pass?
    assert result.provider_usage_complete?

    rows = Map.new(result.rows, &{&1.arm, &1})

    assert rows.typed_operations.metrics.serialized_bytes <
             rows.compact_dsl.metrics.serialized_bytes

    assert rows.compact_dsl.metrics.serialized_bytes <
             rows.normalized_json.metrics.serialized_bytes

    assert rows.typed_operations.metrics.provider_usage.output_tokens == 80

    assert {:ok, persisted} =
             WorkflowEvals.record_case(store, result,
               suite: "substrate-bakeoff-v1",
               task_family: "repair",
               model: "openai:gpt-5.6-luna"
             )

    assert length(persisted) == 3
    assert Enum.all?(persisted, &(&1.status == "pass"))

    assert [json, dsl, operations_row] =
             WorkflowEvals.rows(store, "substrate-bakeoff-v1", case_id: "repair-policy")

    assert Enum.map([json, dsl, operations_row], & &1.arm) == [
             "compact_dsl",
             "normalized_json",
             "typed_operations"
           ]

    assert Enum.all?([json, dsl, operations_row], &(&1.model == "openai:gpt-5.6-luna"))
  end

  test "retains a Pareto set instead of collapsing quality and cost", %{store: store} do
    assert {:ok, quality} =
             WorkflowEvals.create_candidate(store,
               name: "planner-bundle",
               task_family: "research",
               modules: %{planner: "contract-first detailed planner"},
               metrics: %{
                 verified_success_rate: 0.96,
                 human_comprehension: 0.9,
                 output_tokens: 900,
                 latency_ms: 1_200,
                 cost_usd: 0.03,
                 unsafe_effect_rate: 0.0
               },
               feedback: %{strength: "highest held-out quality"}
             )

    assert {:ok, efficient} =
             WorkflowEvals.create_candidate(store,
               name: "planner-bundle",
               task_family: "research",
               parent_ids: [quality.id],
               modules: %{planner: "compact contract-on-demand planner"},
               metrics: %{
                 verified_success_rate: 0.93,
                 human_comprehension: 0.9,
                 output_tokens: 400,
                 latency_ms: 700,
                 cost_usd: 0.01,
                 unsafe_effect_rate: 0.0
               },
               feedback: %{strength: "lower total cost"}
             )

    assert {:ok, dominated} =
             WorkflowEvals.create_candidate(store,
               name: "planner-bundle",
               task_family: "research",
               parent_ids: [quality.id],
               modules: %{planner: "verbose weaker planner"},
               metrics: %{
                 verified_success_rate: 0.8,
                 human_comprehension: 0.7,
                 output_tokens: 1_100,
                 latency_ms: 1_500,
                 cost_usd: 0.04,
                 unsafe_effect_rate: 0.01
               },
               feedback: %{weakness: "dominated on every release metric"}
             )

    assert {:ok, refreshed} = WorkflowEvals.refresh_pareto(store, "research")

    frontier = refreshed |> Enum.filter(& &1.pareto) |> Enum.map(& &1.id) |> MapSet.new()
    assert MapSet.equal?(frontier, MapSet.new([quality.id, efficient.id]))
    refute MapSet.member?(frontier, dominated.id)
  end
end
