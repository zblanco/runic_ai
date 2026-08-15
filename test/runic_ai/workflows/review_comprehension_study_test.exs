defmodule RunicAI.Workflows.ReviewComprehensionStudyTest do
  use ExUnit.Case, async: true

  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.WorkflowEvals
  alias RunicAI.Workflows.ReviewComprehensionStudy

  setup do
    {:ok, store} = SQLite.open(":memory:")
    on_exit(fn -> SQLite.close(store) end)
    %{store: store}
  end

  test "counterbalances both arms across the two cases" do
    [first, second] = ReviewComprehensionStudy.cases()

    assert ReviewComprehensionStudy.assigned_arm("operator-a", first.id) !=
             ReviewComprehensionStudy.assigned_arm("operator-a", second.id)

    assert ReviewComprehensionStudy.assigned_arm("operator-b", first.id) !=
             ReviewComprehensionStudy.assigned_arm("operator-b", second.id)
  end

  test "scores and durably records comprehension and attention metrics", %{store: store} do
    {:ok, study_case} = ReviewComprehensionStudy.fetch_case("unsafe-write-retry")
    answers = %{"scope" => "workspace_write", "retry" => "3", "decision" => "reject"}

    assert %{all_correct?: true, comprehension: 1.0} =
             ReviewComprehensionStudy.score(study_case, answers)

    assert {:ok, [_row]} =
             ReviewComprehensionStudy.record(
               store,
               study_case,
               "operator-a",
               :semantic,
               answers,
               elapsed_ms: 4_200,
               actions: 2
             )

    assert [persisted] = WorkflowEvals.rows(store, ReviewComprehensionStudy.suite())
    assert persisted.arm == "semantic"
    assert persisted.status == "pass"
    assert persisted.metrics_json["human_comprehension"] == 1.0
    assert persisted.metrics_json["elapsed_ms"] == 4_200
    assert persisted.metrics_json["review_actions"] == 2
    assert persisted.artifacts_json["participant_kind"] == "human"
  end

  test "summarizes latest human rows by arm and excludes scripted fixtures", %{store: store} do
    [unsafe_case, verification_case] = ReviewComprehensionStudy.cases()

    unsafe_correct = %{"scope" => "workspace_write", "retry" => "3", "decision" => "reject"}
    unsafe_partial = Map.put(unsafe_correct, "decision", "approve")

    verification_correct = %{
      "component" => "claim_verifier",
      "flow" => "verified",
      "proof" => "verdicts"
    }

    assert {:ok, _rows} =
             ReviewComprehensionStudy.record(
               store,
               unsafe_case,
               "operator-a",
               :semantic,
               unsafe_correct,
               elapsed_ms: 1_000
             )

    assert {:ok, _rows} =
             ReviewComprehensionStudy.record(
               store,
               verification_case,
               "operator-a",
               :raw_json,
               verification_correct,
               elapsed_ms: 3_000
             )

    assert {:ok, _rows} =
             ReviewComprehensionStudy.record(
               store,
               unsafe_case,
               "operator-b",
               :raw_json,
               unsafe_partial,
               elapsed_ms: 5_000
             )

    assert {:ok, _rows} =
             ReviewComprehensionStudy.record(
               store,
               verification_case,
               "operator-b",
               :semantic,
               verification_correct,
               elapsed_ms: 2_000
             )

    assert {:ok, _rows} =
             ReviewComprehensionStudy.record(
               store,
               unsafe_case,
               "browser-proof-a",
               :semantic,
               unsafe_correct,
               elapsed_ms: 1,
               participant_kind: :scripted
             )

    summary = ReviewComprehensionStudy.summary(store)

    assert summary.participant_count == 2
    assert summary.complete_participant_count == 2
    assert summary.included_row_count == 4
    assert summary.excluded_scripted_row_count == 1
    assert summary.arms.semantic.row_count == 2
    assert summary.arms.semantic.all_correct_rate == 1.0
    assert summary.arms.semantic.median_elapsed_ms == 1_500.0
    assert summary.arms.raw_json.row_count == 2
    assert summary.arms.raw_json.all_correct_rate == 0.5
    assert summary.arms.raw_json.median_elapsed_ms == 4_000.0
  end
end
