defmodule Mix.Tasks.RunicAi.WorkflowReviewStudyReport do
  @moduledoc """
  Summarizes actual participant results from the counterbalanced workflow review study.

      mix runic_ai.workflow_review_study_report
      mix runic_ai.workflow_review_study_report --json
      mix runic_ai.workflow_review_study_report --include-scripted

  Scripted Chrome fixtures are excluded by default.
  """

  use Mix.Task

  alias RunicAI.Workbench
  alias RunicAI.Workflows.ReviewComprehensionStudy

  @shortdoc "Report workflow review comprehension and attention metrics"

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [json: :boolean, include_scripted: :boolean]
      )

    if invalid != [] do
      Mix.raise("invalid workflow review study report options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    summary =
      ReviewComprehensionStudy.summary(Workbench.store!(),
        include_scripted?: Keyword.get(opts, :include_scripted, false)
      )

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(Jason.encode!(summary, pretty: true))
    else
      Mix.shell().info(markdown(summary))
    end
  end

  defp markdown(summary) do
    semantic = summary.arms.semantic
    raw = summary.arms.raw_json

    """
    # Workflow Review Study Report

    Human participants: #{summary.participant_count}
    Complete two-case participants: #{summary.complete_participant_count}
    Included rows: #{summary.included_row_count}
    Excluded scripted rows: #{summary.excluded_scripted_row_count}

    | Arm | Rows | All correct | Median comprehension | Median elapsed | Median actions |
    | --- | ---: | ---: | ---: | ---: | ---: |
    | Semantic | #{semantic.row_count} | #{percentage(semantic.all_correct_rate)} | #{decimal(semantic.median_comprehension)} | #{milliseconds(semantic.median_elapsed_ms)} | #{decimal(semantic.median_review_actions)} |
    | Raw JSON | #{raw.row_count} | #{percentage(raw.all_correct_rate)} | #{decimal(raw.median_comprehension)} | #{milliseconds(raw.median_elapsed_ms)} | #{decimal(raw.median_review_actions)} |
    """
  end

  defp percentage(nil), do: "n/a"
  defp percentage(value), do: "#{Float.round(value * 100, 1)}%"

  defp decimal(nil), do: "n/a"
  defp decimal(value) when is_integer(value), do: Integer.to_string(value)
  defp decimal(value), do: value |> Kernel.*(1.0) |> Float.round(2) |> to_string()

  defp milliseconds(nil), do: "n/a"
  defp milliseconds(value) when is_integer(value), do: "#{value} ms"
  defp milliseconds(value), do: "#{Float.round(value, 1)} ms"
end
