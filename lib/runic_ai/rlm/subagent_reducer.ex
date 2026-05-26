defmodule RunicAI.RLM.SubagentReducer do
  @moduledoc """
  Reduces and reviews subagent outputs for RLM-style delegation.

  The reducer expects child outputs to include claim-shaped records. It keeps
  enough metadata for the parent coordinator to distinguish agreement,
  disagreement, missing evidence, unsupported claims, and low-confidence work
  before synthesis or materialization.
  """

  alias RunicAI.Decomposition.Result
  alias RunicAI.Error

  @review_statuses [:accepted, :review, :failed]
  @terminal_problem_statuses [:failed, :cancelled]

  @spec review_statuses() :: [atom()]
  def review_statuses, do: @review_statuses

  @spec reduce([Result.t() | map()], keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  def reduce(results, opts \\ [])

  def reduce(results, opts) when is_list(results) do
    opts = opts_map(opts)

    with {:ok, results} <- normalize_results(results) do
      claims =
        results
        |> Enum.flat_map(&claims_for_result/1)
        |> Enum.with_index(1)
        |> Enum.map(fn {claim, index} -> Map.put_new(claim, :id, "claim:#{index}") end)

      conflicts = conflicts(claims)
      unsupported = unsupported_claims(claims, opts)
      missing_info = missing_info_claims(claims)
      incomplete = incomplete_results(results)
      agreements = agreement_groups(claims)
      confidence = confidence_summary(claims)
      status = review_status(results, conflicts, unsupported, missing_info, confidence, opts)

      {:ok,
       %{
         status: status,
         claims: claims,
         claim_count: length(claims),
         agreements: agreements,
         conflicts: conflicts,
         unsupported_claims: unsupported,
         missing_info_claims: missing_info,
         incomplete_results: incomplete,
         confidence: confidence,
         summary:
           summary(status, claims, agreements, conflicts, unsupported, missing_info, incomplete)
       }}
    end
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  def reduce(results, _opts) do
    {:error,
     Error.validation("subagent reducer requires a list of child results",
       source: __MODULE__,
       details: %{results: results}
     )}
  end

  defp normalize_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case Result.from_input(result) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp claims_for_result(%Result{} = result) do
    result.output
    |> output_claims()
    |> Enum.with_index(1)
    |> Enum.map(fn {claim, index} ->
      normalize_claim(claim, result, index)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp output_claims(%{claims: claims}) when is_list(claims), do: claims
  defp output_claims(%{"claims" => claims}) when is_list(claims), do: claims
  defp output_claims(claims) when is_list(claims), do: claims
  defp output_claims(%{claim: claim} = output) when is_binary(claim), do: [output]
  defp output_claims(%{"claim" => claim} = output) when is_binary(claim), do: [output]
  defp output_claims(_output), do: []

  defp normalize_claim(claim, %Result{} = result, index) when is_binary(claim) do
    normalize_claim(%{claim: claim}, result, index)
  end

  defp normalize_claim(claim, %Result{} = result, index) when is_map(claim) do
    text = string_field(claim, :claim) || string_field(claim, :summary)

    if blank?(text) do
      nil
    else
      %{
        id: string_field(claim, :id) || "#{result.task_id}:claim:#{index}",
        claim: text,
        normalized_claim: normalize_text(text),
        task_id: result.task_id,
        role: map_get(result.metadata, :role, string_field(claim, :role)),
        source_slice_id:
          map_get(result.metadata, :context_slice_id, string_field(claim, :source_slice_id)),
        evidence_refs: string_list(map_get(claim, :evidence_refs, map_get(claim, :evidence, []))),
        confidence:
          confidence(map_get(claim, :confidence, map_get(result.metadata, :confidence, nil))),
        missing_info?:
          truthy?(map_get(claim, :missing_info?, map_get(claim, :missing_info, false))),
        unsupported?: truthy?(map_get(claim, :unsupported?, false)),
        conflicts_with: string_list(map_get(claim, :conflicts_with, [])),
        reviewer_notes: string_list(map_get(claim, :reviewer_notes, map_get(claim, :notes, []))),
        metadata: map_get(claim, :metadata, %{})
      }
    end
  end

  defp normalize_claim(_claim, _result, _index), do: nil

  defp conflicts(claims) do
    by_id = Map.new(claims, &{&1.id, &1})
    by_text = Map.new(claims, &{&1.normalized_claim, &1})

    claims
    |> Enum.flat_map(fn claim ->
      Enum.map(claim.conflicts_with, fn target ->
        target_claim = Map.get(by_id, target) || Map.get(by_text, normalize_text(target))

        %{
          claim_id: claim.id,
          claim: claim.claim,
          conflicts_with: target,
          target_claim_id: target_claim && target_claim.id,
          target_claim: target_claim && target_claim.claim,
          evidence_refs: claim.evidence_refs
        }
      end)
    end)
  end

  defp unsupported_claims(claims, opts) do
    allow_unsupported? = truthy?(opt(opts, :allow_unsupported?, false))

    if allow_unsupported? do
      []
    else
      Enum.filter(claims, &(&1.unsupported? or &1.evidence_refs == []))
    end
  end

  defp missing_info_claims(claims), do: Enum.filter(claims, & &1.missing_info?)

  defp incomplete_results(results) do
    results
    |> Enum.reject(&(&1.status == :completed))
    |> Enum.map(fn result ->
      %{
        task_id: result.task_id,
        status: result.status,
        error: result.error && result.error.message,
        metadata: result.metadata
      }
    end)
  end

  defp agreement_groups(claims) do
    claims
    |> Enum.group_by(& &1.normalized_claim)
    |> Enum.filter(fn {_claim, claims} -> length(claims) > 1 end)
    |> Enum.map(fn {_normalized, claims} ->
      %{
        claim: hd(claims).claim,
        count: length(claims),
        claim_ids: Enum.map(claims, & &1.id),
        task_ids: claims |> Enum.map(& &1.task_id) |> Enum.uniq(),
        evidence_refs: claims |> Enum.flat_map(& &1.evidence_refs) |> Enum.uniq(),
        confidence: confidence_summary(claims)
      }
    end)
  end

  defp confidence_summary(claims) do
    values =
      claims
      |> Enum.map(& &1.confidence)
      |> Enum.filter(&is_number/1)

    case values do
      [] ->
        %{count: 0, min: nil, max: nil, average: nil}

      values ->
        %{
          count: length(values),
          min: Enum.min(values),
          max: Enum.max(values),
          average: Enum.sum(values) / length(values)
        }
    end
  end

  defp review_status(results, conflicts, unsupported, missing_info, confidence, opts) do
    threshold = opt(opts, :min_confidence, 0.55)

    cond do
      Enum.any?(results, &(&1.status in @terminal_problem_statuses)) ->
        :failed

      conflicts != [] or unsupported != [] or missing_info != [] or
          low_confidence?(confidence, threshold) ->
        :review

      true ->
        :accepted
    end
  end

  defp low_confidence?(%{average: nil}, _threshold), do: false
  defp low_confidence?(%{average: average}, threshold), do: average < threshold

  defp summary(status, claims, agreements, conflicts, unsupported, missing_info, incomplete) do
    %{
      status: status,
      claim_count: length(claims),
      agreement_count: length(agreements),
      conflict_count: length(conflicts),
      unsupported_count: length(unsupported),
      missing_info_count: length(missing_info),
      incomplete_count: length(incomplete)
    }
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)

  defp opt(opts, key, default) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp string_field(map, key) do
    case map_get(map, key, nil) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      nil -> nil
      value -> to_string(value)
    end
  end

  defp string_list(values) do
    values
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp confidence(nil), do: nil
  defp confidence(value) when is_number(value), do: value

  defp confidence(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp confidence(_value), do: nil

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp blank?(value), do: normalize_text(value) == ""

  defp truthy?(value), do: value in [true, true, "true", "yes", "1", 1]
end
