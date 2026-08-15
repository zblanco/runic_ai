defmodule RunicAI.Workflows.ReviewComprehensionStudy do
  @moduledoc """
  Counterbalanced human-comprehension study for workflow review projections.

  Each participant sees each case in exactly one arm. The assignment alternates
  by participant cohort and case index so a two-case session contains one
  semantic projection and one raw JSON projection without showing the same
  answer twice.
  """

  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.WorkflowEvals

  @suite "workflow-review-comprehension-v1"

  @unsafe_questions [
    %{
      id: "scope",
      prompt: "Which capability becomes broader?",
      options: [
        %{value: "workspace_write", label: "Workspace writes"},
        %{value: "network", label: "Network access"},
        %{value: "model", label: "Model access"}
      ],
      answer: "workspace_write"
    },
    %{
      id: "retry",
      prompt: "How many retries are proposed for the writer?",
      options: [
        %{value: "0", label: "0"},
        %{value: "1", label: "1"},
        %{value: "3", label: "3"}
      ],
      answer: "3"
    },
    %{
      id: "decision",
      prompt: "What is the safe review decision as written?",
      options: [
        %{value: "reject", label: "Reject and request reconciliation"},
        %{value: "approve", label: "Approve"},
        %{value: "ignore", label: "Ignore the change"}
      ],
      answer: "reject"
    }
  ]

  @verification_questions [
    %{
      id: "component",
      prompt: "Which component is added?",
      options: [
        %{value: "claim_verifier", label: "claim_verifier@2"},
        %{value: "source_discovery", label: "source_discovery@1"},
        %{value: "artifact_writer", label: "artifact_writer@1"}
      ],
      answer: "claim_verifier"
    },
    %{
      id: "flow",
      prompt: "What is the new flow into the writer?",
      options: [
        %{value: "verified", label: "research → verify → write"},
        %{value: "unchanged", label: "research → write"},
        %{value: "reversed", label: "write → verify → research"}
      ],
      answer: "verified"
    },
    %{
      id: "proof",
      prompt: "What new completion proof is required?",
      options: [
        %{value: "verdicts", label: "Every finding has a verifier verdict"},
        %{value: "runtime", label: "The run finishes within four seconds"},
        %{value: "none", label: "No new proof"}
      ],
      answer: "verdicts"
    }
  ]

  @cases [
    %{
      id: "unsafe-write-retry",
      title: "Expanded write access and retries",
      objective: "Write a verified report under the existing docs-only policy.",
      context:
        "The writer performs an opaque host mutation. It has no idempotency key, reconciliation check, or compensation.",
      operations: [
        %{op: "set_policy", key: "write_policy", value: "workspace_review"},
        %{op: "set_policy", node_id: "write", key: "max_retries", value: 3}
      ],
      diff: %{},
      diagnostics: [
        %{
          severity: "error",
          code: "unsafe_retry",
          message: "Automatic retry is unsafe for an opaque host mutation without reconciliation."
        }
      ],
      questions: @unsafe_questions
    },
    %{
      id: "insert-verification",
      title: "Verify findings before writing",
      objective: "Add explicit verification without changing discovery behavior.",
      context:
        "The current flow sends research.findings directly to write.report. The verifier is cataloged and policy-compatible.",
      operations: [
        %{
          op: "add_node",
          node: %{id: "verify", component: "claim_verifier@2", arguments: %{max_items: 4}}
        },
        %{op: "disconnect", edge_id: "research:write"},
        %{
          op: "connect",
          from: %{node: "research", port: "findings"},
          to: %{node: "verify", port: "items"}
        },
        %{
          op: "connect",
          from: %{node: "verify", port: "verdicts"},
          to: %{node: "write", port: "report"}
        },
        %{
          op: "set_acceptance",
          acceptance_id: "all_findings_verified",
          check: %{description: "Every finding has a verifier verdict", required: true}
        }
      ],
      diff: %{},
      diagnostics: [],
      questions: @verification_questions
    }
  ]

  @spec suite() :: String.t()
  def suite, do: @suite

  @spec cases() :: [map()]
  def cases, do: @cases

  @spec fetch_case(String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch_case(case_id) when is_binary(case_id) do
    case Enum.find(@cases, &(&1.id == case_id)) do
      nil -> {:error, :not_found}
      study_case -> {:ok, study_case}
    end
  end

  @spec assigned_arm(String.t(), String.t()) :: :semantic | :raw_json
  def assigned_arm(participant_id, case_id)
      when is_binary(participant_id) and is_binary(case_id) do
    case_index = Enum.find_index(@cases, &(&1.id == case_id)) || 0
    cohort = :erlang.phash2(participant_id, 2)
    if rem(cohort + case_index, 2) == 0, do: :semantic, else: :raw_json
  end

  @spec public_payload(map()) :: map()
  def public_payload(study_case) do
    Map.take(study_case, [:id, :title, :objective, :context, :operations, :diff, :diagnostics])
  end

  @spec score(map(), map()) :: map()
  def score(study_case, answers) when is_map(study_case) and is_map(answers) do
    question_results =
      Enum.map(study_case.questions, fn question ->
        answer =
          Enum.find_value(answers, fn {key, value} ->
            if to_string(key) == question.id, do: value
          end)

        %{
          id: question.id,
          answer: answer,
          expected: question.answer,
          correct?: answer == question.answer
        }
      end)

    correct = Enum.count(question_results, & &1.correct?)
    total = length(question_results)

    %{
      correct: correct,
      total: total,
      comprehension: if(total == 0, do: 0.0, else: correct / total),
      all_correct?: correct == total,
      question_results: question_results
    }
  end

  @spec record(Store.t(), map(), String.t(), atom(), map(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def record(%Store{} = store, study_case, participant_id, arm, answers, opts \\ [])
      when arm in [:semantic, :raw_json] do
    result = score(study_case, answers)
    elapsed_ms = Keyword.fetch!(opts, :elapsed_ms)
    actions = Keyword.get(opts, :actions, 2)
    participant_kind = Keyword.get(opts, :participant_kind, :human)

    row = %{
      arm: arm,
      status: if(result.all_correct?, do: :pass, else: :fail),
      metrics: %{
        human_comprehension: result.comprehension,
        correct_answers: result.correct,
        total_answers: result.total,
        elapsed_ms: elapsed_ms,
        review_actions: actions
      },
      diagnostics: %{question_results: result.question_results},
      artifacts: %{
        participant_id: participant_id,
        participant_kind: participant_kind,
        presentation: public_payload(study_case),
        answers: answers
      }
    }

    WorkflowEvals.record_case(
      store,
      %{case_id: "#{study_case.id}:#{participant_id}", rows: [row]},
      suite: @suite,
      task_family: "human_workflow_review"
    )
  end

  @spec summary(Store.t(), keyword()) :: map()
  def summary(%Store{} = store, opts \\ []) do
    rows =
      store
      |> WorkflowEvals.rows(@suite)
      |> latest_participant_case_rows()

    {scripted, human} = Enum.split_with(rows, &scripted_row?/1)
    included = if Keyword.get(opts, :include_scripted?, false), do: rows, else: human

    participants =
      included |> Enum.map(&participant_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    complete_participants =
      included
      |> Enum.group_by(&participant_id/1)
      |> Enum.count(fn {participant, participant_rows} ->
        not is_nil(participant) and
          participant_rows
          |> Enum.map(&case_id/1)
          |> Enum.uniq()
          |> length() == length(@cases)
      end)

    %{
      suite: @suite,
      participant_count: length(participants),
      complete_participant_count: complete_participants,
      included_row_count: length(included),
      excluded_scripted_row_count: if(included == rows, do: 0, else: length(scripted)),
      arms: %{
        semantic: arm_summary(included, "semantic"),
        raw_json: arm_summary(included, "raw_json")
      }
    }
  end

  defp latest_participant_case_rows(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc -> Map.put(acc, row.case_id, row) end)
    |> Map.values()
  end

  defp arm_summary(rows, arm) do
    rows = Enum.filter(rows, &(&1.arm == arm))
    comprehensions = metric_values(rows, "human_comprehension")
    elapsed = metric_values(rows, "elapsed_ms")
    actions = metric_values(rows, "review_actions")

    %{
      row_count: length(rows),
      participant_count:
        rows |> Enum.map(&participant_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length(),
      all_correct_rate: rate(Enum.count(rows, &(&1.status == "pass")), length(rows)),
      median_comprehension: median(comprehensions),
      median_elapsed_ms: median(elapsed),
      median_review_actions: median(actions),
      case_counts: Enum.frequencies_by(rows, &case_id/1)
    }
  end

  defp metric_values(rows, key) do
    rows
    |> Enum.map(&Map.get(&1.metrics_json || %{}, key))
    |> Enum.filter(&is_number/1)
  end

  defp participant_id(row), do: Map.get(row.artifacts_json || %{}, "participant_id")

  defp case_id(row) do
    row.case_id
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp scripted_row?(row) do
    artifacts = row.artifacts_json || %{}
    kind = Map.get(artifacts, "participant_kind")
    participant = Map.get(artifacts, "participant_id", "")

    kind == "scripted" or
      Enum.any?(
        ["browser-proof-", "scripted-", "automation-"],
        &String.starts_with?(participant, &1)
      )
  end

  defp rate(_count, 0), do: nil
  defp rate(count, total), do: count / total

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end
end
