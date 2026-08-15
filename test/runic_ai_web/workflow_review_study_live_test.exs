defmodule RunicAIWeb.WorkflowReviewStudyLiveTest do
  use RunicAIWeb.ConnCase, async: false

  alias RunicAI.Persistence.WorkflowEvals
  alias RunicAI.Workbench
  alias RunicAI.Workflows.ReviewComprehensionStudy

  test "counterbalanced browser reviews retain correctness and attention evidence", %{conn: conn} do
    participant = "browser-proof-test-#{System.unique_integer([:positive])}"

    seen_arms =
      Enum.map(ReviewComprehensionStudy.cases(), fn study_case ->
        arm = ReviewComprehensionStudy.assigned_arm(participant, study_case.id)

        {:ok, view, html} =
          live(
            conn,
            ~p"/workflow-review-study/#{study_case.id}?participant=#{participant}"
          )

        assert html =~ "Begin timed review"

        html = view |> element("#begin-review-study") |> render_click()
        assert html =~ study_case.objective

        case arm do
          :semantic ->
            assert has_element?(view, "#study-semantic-view[data-study-arm='semantic']")
            refute has_element?(view, "#study-raw-json-view")

          :raw_json ->
            assert has_element?(view, "#study-raw-json-view[data-study-arm='raw_json']")
            refute has_element?(view, "#study-semantic-view")
        end

        answers = Map.new(study_case.questions, &{&1.id, &1.answer})

        html =
          view
          |> form("#review-study-form", answers: answers)
          |> render_submit()

        assert html =~ "3/3 correct"
        assert html =~ "Result recorded"

        rows =
          WorkflowEvals.rows(
            Workbench.store!(),
            ReviewComprehensionStudy.suite(),
            case_id: "#{study_case.id}:#{participant}"
          )

        assert [row] = rows
        assert row.status == "pass"
        assert row.arm == Atom.to_string(arm)
        assert row.metrics_json["human_comprehension"] == 1.0
        assert row.metrics_json["review_actions"] == 2
        assert is_integer(row.metrics_json["elapsed_ms"])
        assert row.artifacts_json["participant_kind"] == "scripted"

        arm
      end)

    assert MapSet.new(seen_arms) == MapSet.new([:semantic, :raw_json])
  end
end
