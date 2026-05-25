defmodule RunicAI.RLM.Robustness.Judge do
  @moduledoc """
  Heuristic and optional LLM judge for robustness project scenarios.
  """

  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.RLM.Robustness.ProjectScenario

  @dimensions [
    :intent_translation,
    :workflow_planning,
    :dependency_selection,
    :architecture_quality,
    :domain_correctness,
    :test_quality,
    :verification_honesty,
    :repair_effectiveness,
    :user_output_quality
  ]

  @default_model "openai:gpt-5.4-mini"
  @valid_overall ~w(pass review fail)
  @audit_excerpt_limit 4_000

  @spec evaluate(ProjectScenario.t(), map(), keyword()) :: map()
  def evaluate(%ProjectScenario{} = scenario, evidence, opts \\ []) when is_map(evidence) do
    if Keyword.get(opts, :llm_judge?, false) do
      llm_judge(scenario, evidence, opts)
    else
      heuristic_judge(scenario, evidence)
    end
  end

  @spec schema() :: keyword()
  def schema do
    [
      overall: [type: :string, required: true],
      scores: [type: :map, required: true],
      blocking_failures: [type: {:list, :string}],
      notable_strengths: [type: {:list, :string}],
      evidence: [type: {:list, :string}]
    ]
  end

  @spec prompt(ProjectScenario.t(), map()) :: String.t()
  def prompt(%ProjectScenario{} = scenario, evidence) when is_map(evidence) do
    """
    You are judging a RunicAI RLM robustness smoke.

    Objective:
    #{scenario.prompt}

    Judge rubric:
    #{Jason.encode!(scenario.judge_rubric)}

    Evidence JSON:
    #{Jason.encode!(json_safe(evidence))}

    Return JSON with fields overall, scores, blocking_failures,
    notable_strengths, and evidence. overall must be pass, review, or fail.
    Scores are integers 0 or 1 for #{Enum.join(Enum.map(@dimensions, &Atom.to_string/1), ", ")}.
    Do not pass a run that failed deterministic compile, test, runtime, or
    required source checks.
    """
  end

  defp heuristic_judge(%ProjectScenario{} = scenario, evidence) do
    deterministic = Map.get(evidence, :deterministic, %{})
    checks = Map.get(deterministic, :checks, [])
    passed = Map.get(deterministic, :passed, 0)
    total = max(Map.get(deterministic, :total, length(checks)), 1)
    ratio = passed / total

    command_failures =
      Enum.filter(
        checks,
        &(get_in(&1, [:check, :type]) == :command_passes and &1.status != :pass)
      )

    source_failures =
      Enum.filter(
        checks,
        &(get_in(&1, [:check, :type]) in [:source_contains, :source_not_contains] and
            &1.status != :pass)
      )

    test_failures =
      Enum.filter(
        checks,
        &(get_in(&1, [:check, :type]) == :test_count_min and &1.status != :pass)
      )

    scores = %{
      intent_translation: score_from_ratio(ratio),
      workflow_planning: score_from_presence(evidence, [:agent_result, :browser_snapshot]),
      dependency_selection: dependency_score(evidence),
      architecture_quality: source_score(source_failures, ratio),
      domain_correctness: score_from_ratio(ratio),
      test_quality: if(test_failures == [], do: 1, else: 0),
      verification_honesty: if(command_failures == [], do: 1, else: 0),
      repair_effectiveness: repair_score(evidence),
      user_output_quality: user_output_score(evidence)
    }

    blocking =
      []
      |> maybe_block(command_failures != [], "compile/test/runtime command checks failed")
      |> maybe_block(source_failures != [], "domain/source evidence checks failed")
      |> maybe_block(test_failures != [], "behavioral test minimum was not met")
      |> maybe_block(
        Map.get(evidence, :lane_status) in [:skipped, "skipped"],
        "lane execution was skipped"
      )
      |> maybe_block(
        Map.get(evidence, :lane_status) in [:error, "error"],
        "lane execution errored"
      )
      |> maybe_block(
        Map.get(evidence, :lane_status) in [:failed, "failed"],
        "lane execution failed"
      )
      |> maybe_block(
        Map.get(evidence, :lane_status) in [:blocked, "blocked"],
        "lane execution blocked"
      )
      |> maybe_block(
        Map.get(evidence, :ui_gaps, []) != [],
        ui_gap_blocking_message(Map.get(evidence, :ui_gaps, []))
      )

    %{
      overall: overall(blocking, ratio),
      scores: scores,
      blocking_failures: blocking,
      notable_strengths: strengths(scores, scenario),
      evidence: evidence_lines(evidence),
      audit: %{
        source: :heuristic,
        llm_judge?: false,
        deterministic_status: Map.get(deterministic, :status),
        lane_status: Map.get(evidence, :lane_status)
      }
    }
  end

  defp llm_judge(%ProjectScenario{} = scenario, evidence, opts) do
    model = Keyword.get(opts, :model, @default_model)
    llm_opts = opts |> Keyword.get(:llm_opts, []) |> maybe_put_client(Keyword.get(opts, :client))
    prompt = prompt(scenario, evidence)

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        response_text = Result.text(result)

        case decode_judge(response_text) do
          {:ok, judge} ->
            judge
            |> normalize_judge()
            |> apply_deterministic_gate(evidence)
            |> put_audit(
              llm_audit(:llm, model, prompt,
                response_text: response_text,
                fallback?: false
              )
            )

          {:error, error} ->
            llm_fallback_judge(scenario, evidence, model, prompt,
              response_text: response_text,
              error: error,
              reason: :decode_failed
            )
        end

      {:retry, error} ->
        llm_fallback_judge(scenario, evidence, model, prompt,
          error: error,
          reason: :retryable_provider_error
        )

      {:error, error} ->
        llm_fallback_judge(scenario, evidence, model, prompt,
          error: error,
          reason: :provider_error
        )
    end
  end

  defp decode_judge(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/, "")
    |> String.replace(~r/\s*```\z/, "")
    |> Jason.decode()
  end

  defp normalize_judge(judge) when is_map(judge) do
    %{
      overall: normalize_overall(Map.get(judge, "overall", Map.get(judge, :overall, "review"))),
      scores: normalize_scores(Map.get(judge, "scores", Map.get(judge, :scores, %{}))),
      blocking_failures:
        string_list(Map.get(judge, "blocking_failures", Map.get(judge, :blocking_failures, []))),
      notable_strengths:
        string_list(Map.get(judge, "notable_strengths", Map.get(judge, :notable_strengths, []))),
      evidence: string_list(Map.get(judge, "evidence", Map.get(judge, :evidence, [])))
    }
  end

  defp llm_fallback_judge(scenario, evidence, model, prompt, opts) do
    response_text = Keyword.get(opts, :response_text)

    scenario
    |> heuristic_judge(evidence)
    |> put_audit(
      llm_audit(:heuristic_fallback, model, prompt,
        response_text: response_text,
        fallback?: true,
        fallback_reason: Keyword.fetch!(opts, :reason),
        error: Keyword.get(opts, :error)
      )
    )
  end

  defp apply_deterministic_gate(judge, evidence) do
    blocking = deterministic_gate_blocks(evidence)

    if blocking == [] do
      judge
    else
      judge
      |> Map.update!(:blocking_failures, &Enum.uniq(&1 ++ blocking))
      |> Map.put(:overall, "fail")
    end
  end

  defp deterministic_gate_blocks(evidence) do
    deterministic = Map.get(evidence, :deterministic, %{})
    status = Map.get(deterministic, :status)
    lane_status = Map.get(evidence, :lane_status)

    []
    |> maybe_block(
      status not in [:pass, "pass"],
      "deterministic gates failed; LLM pass downgraded"
    )
    |> maybe_block(lane_status in [:skipped, "skipped"], "lane execution was skipped")
    |> maybe_block(lane_status in [:error, "error"], "lane execution errored")
    |> maybe_block(lane_status in [:failed, "failed"], "lane execution failed")
    |> maybe_block(lane_status in [:blocked, "blocked"], "lane execution blocked")
    |> Enum.reverse()
  end

  defp normalize_overall(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_overall()

  defp normalize_overall(value) when is_binary(value) do
    value = value |> String.downcase() |> String.trim()
    if value in @valid_overall, do: value, else: "review"
  end

  defp normalize_overall(_value), do: "review"

  defp normalize_scores(scores) when is_map(scores) do
    Map.new(@dimensions, fn dimension ->
      value =
        Map.get(scores, Atom.to_string(dimension), Map.get(scores, dimension, 0))

      {dimension, if(value in [1, "1", true], do: 1, else: 0)}
    end)
  end

  defp normalize_scores(_scores), do: normalize_scores(%{})

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp string_list(nil), do: []
  defp string_list(value), do: [to_string(value)]

  defp put_audit(judge, audit), do: Map.put(judge, :audit, audit)

  defp llm_audit(source, model, prompt, opts) do
    %{
      source: source,
      llm_judge?: true,
      model: model,
      prompt_sha256: sha256(prompt),
      prompt_excerpt: excerpt(prompt),
      response_excerpt: excerpt(Keyword.get(opts, :response_text)),
      fallback?: Keyword.get(opts, :fallback?, false)
    }
    |> maybe_put(:fallback_reason, Keyword.get(opts, :fallback_reason))
    |> maybe_put(:error, format_error(Keyword.get(opts, :error)))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp sha256(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp excerpt(nil), do: nil

  defp excerpt(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, @audit_excerpt_limit)
  end

  defp format_error(nil), do: nil
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(error), do: inspect(error, limit: 20)

  defp score_from_ratio(ratio) when ratio >= 0.8, do: 1
  defp score_from_ratio(_ratio), do: 0

  defp score_from_presence(evidence, keys) do
    if Enum.any?(keys, &Map.has_key?(evidence, &1)), do: 1, else: 0
  end

  defp dependency_score(_evidence), do: 1

  defp source_score([], ratio), do: score_from_ratio(ratio)
  defp source_score(_failures, _ratio), do: 0

  defp repair_score(evidence) do
    repair_count = Map.get(evidence, :repair_count, 0)
    if repair_count > 0, do: 1, else: 0
  end

  defp user_output_score(evidence) do
    output =
      Map.get(evidence, :final_output) || get_in(evidence, [:browser_snapshot, :final_output])

    if is_binary(output) and String.trim(output) != "", do: 1, else: 0
  end

  defp maybe_block(blocks, true, message), do: [message | blocks]
  defp maybe_block(blocks, false, _message), do: blocks

  defp ui_gap_blocking_message(gaps) when is_list(gaps) do
    if Enum.all?(gaps, &String.contains?(&1, "follow-up")) do
      "browser/Tidewave follow-up interaction is incomplete"
    else
      "browser/UI evidence capture is incomplete"
    end
  end

  defp ui_gap_blocking_message(_gaps), do: "browser/UI evidence capture is incomplete"

  defp overall([], ratio) when ratio >= 0.9, do: "pass"
  defp overall([], _ratio), do: "review"
  defp overall(_blocking, _ratio), do: "fail"

  defp strengths(scores, scenario) do
    scores
    |> Enum.filter(fn {_key, score} -> score == 1 end)
    |> Enum.map(fn {key, _score} -> "#{key} acceptable for #{scenario.id}" end)
  end

  defp evidence_lines(evidence) do
    [
      "lane=#{Map.get(evidence, :lane)}",
      "workspace=#{Map.get(evidence, :workspace)}",
      "deterministic=#{get_in(evidence, [:deterministic, :status])}"
    ]
    |> Enum.reject(&String.ends_with?(&1, "="))
  end

  defp maybe_put_client(opts, nil), do: opts
  defp maybe_put_client(opts, client), do: Keyword.put_new(opts, :client, client)

  defp json_safe(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
