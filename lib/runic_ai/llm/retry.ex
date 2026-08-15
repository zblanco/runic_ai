defmodule RunicAI.LLM.Retry do
  @moduledoc """
  Provider-aware retry classification and bounded backoff for LLM calls.

  Temporary throttling is distinct from permanent billing or credit failures.
  Provider retry hints are preserved when available so callers do not hammer a
  rate-limited endpoint with a fixed short delay.
  """

  alias RunicAI.Control.RetryPolicy
  alias RunicAI.Error

  @transient_statuses [408, 409, 425, 429, 500, 502, 503, 504]
  @default_max_attempts 3
  @default_base_delay_ms 1_000
  @max_delay_ms 60_000

  @spec default_policy(keyword()) :: RetryPolicy.t()
  def default_policy(opts \\ []) do
    RetryPolicy.new!(
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      backoff: &backoff_ms/2,
      metadata: %{source: __MODULE__, provider_aware?: true}
    )
  end

  @spec retryable_provider_error?(term()) :: boolean()
  def retryable_provider_error?(error) do
    status = field(error, :status)
    diagnostic = diagnostic_text(error)

    status in @transient_statuses and not permanent_quota_failure?(diagnostic)
  end

  @spec permanent_provider_failure?(term()) :: boolean()
  def permanent_provider_failure?(error) do
    error
    |> diagnostic_text()
    |> permanent_quota_failure?()
  end

  @spec retry_after_ms(term()) :: non_neg_integer() | nil
  def retry_after_ms(error) do
    explicit_retry_after_ms(error) || retry_after_header_ms(error) ||
      retry_after_message_ms(error)
  end

  @spec backoff_ms(pos_integer(), term()) :: non_neg_integer()
  def backoff_ms(attempt, outcome) when is_integer(attempt) and attempt > 0 do
    outcome
    |> outcome_error()
    |> retry_after_ms()
    |> case do
      delay when is_integer(delay) -> min(delay, @max_delay_ms)
      _other -> min(@default_base_delay_ms * Integer.pow(2, attempt - 1), @max_delay_ms)
    end
  end

  defp outcome_error({:retry, error}), do: error
  defp outcome_error({:error, error}), do: error
  defp outcome_error(error), do: error

  defp explicit_retry_after_ms(%Error{details: details}), do: field(details, :retry_after_ms)
  defp explicit_retry_after_ms(error), do: field(error, :retry_after_ms)

  defp retry_after_header_ms(error) do
    error
    |> field(:headers)
    |> List.wrap()
    |> Enum.find_value(fn
      {key, value} ->
        if String.downcase(to_string(key)) == "retry-after", do: seconds_to_ms(value)

      _other ->
        nil
    end)
  end

  defp retry_after_message_ms(error) do
    case Regex.run(~r/retry in\s+([0-9]+(?:\.[0-9]+)?)s/i, error_message(error),
           capture: :all_but_first
         ) do
      [seconds] -> seconds_to_ms(seconds)
      _other -> nil
    end
  end

  defp seconds_to_ms(value) do
    case Float.parse(to_string(value)) do
      {seconds, _rest} when seconds >= 0 -> ceil(seconds * 1_000)
      _other -> nil
    end
  end

  defp permanent_quota_failure?(diagnostic) do
    diagnostic = String.downcase(diagnostic)

    billing_or_credit_failure? =
      String.contains?(diagnostic, [
        "insufficient_quota",
        "credit balance is too low",
        "purchase credits",
        "billing details"
      ])

    non_renewing_quota? =
      String.contains?(diagnostic, [
        "requestsperday",
        "tokensperday",
        "perdayperproject",
        "daily quota",
        "daily limit"
      ])

    billing_or_credit_failure? or non_renewing_quota?
  end

  # Provider SDKs frequently put machine-readable quota ids only in a nested
  # response body while the top-level message says to retry. Classification
  # must consider both; otherwise a per-day quota burns attempts on a per-minute
  # retry hint that cannot make the request eligible.
  defp diagnostic_text(error) do
    [
      error_message(error),
      field(error, :response_body),
      field(error, :response_body_preview),
      field(field(error, :details), :response_body),
      field(field(error, :details), :response_body_preview)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", fn value -> inspect(value, limit: 40, printable_limit: 2_000) end)
  end

  defp error_message(%Error{} = error) do
    field(error.details, :reason_message) || error.message
  end

  defp error_message(error) do
    field(error, :reason) || field(error, :message) || inspect(error, limit: 12)
  end

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
