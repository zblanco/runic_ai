defmodule RunicAI.Control.Recovery do
  @moduledoc """
  Generic retry and fallback runner for effect boundaries.
  """

  alias RunicAI.Control.FallbackPolicy
  alias RunicAI.Control.RetryPolicy
  alias RunicAI.Error

  @spec run((-> term()), keyword()) :: term()
  def run(primary_fun, opts \\ []) when is_function(primary_fun, 0) and is_list(opts) do
    retry_policy = RetryPolicy.from_input!(Keyword.get(opts, :retry_policy))
    fallback_policy = FallbackPolicy.from_input!(Keyword.get(opts, :fallback_policy))

    retryable? =
      policy_predicate(retry_policy, :retry_if) ||
        Keyword.get(opts, :retryable?, &default_retryable?/1)

    fallback? =
      policy_predicate(fallback_policy, :fallback_if) ||
        Keyword.get(opts, :fallback?, &default_fallback?/1)

    run_fallback = Keyword.get(opts, :run_fallback, &default_run_fallback/2)

    primary_fun
    |> retry(retry_policy, retryable?)
    |> maybe_fallback(fallback_policy, fallback?, run_fallback)
  end

  defp retry(primary_fun, nil, _retryable?), do: primary_fun.()

  defp retry(primary_fun, %RetryPolicy{} = retry_policy, retryable?) do
    do_retry(primary_fun, retry_policy, retryable?, 1)
  end

  defp do_retry(primary_fun, %RetryPolicy{} = retry_policy, retryable?, attempt) do
    outcome = primary_fun.()

    cond do
      attempt >= retry_policy.max_attempts ->
        outcome

      retryable?.(outcome) ->
        maybe_sleep(retry_policy.backoff, attempt, outcome)
        do_retry(primary_fun, retry_policy, retryable?, attempt + 1)

      true ->
        outcome
    end
  end

  defp maybe_fallback(outcome, nil, _fallback?, _run_fallback), do: outcome

  defp maybe_fallback(outcome, %FallbackPolicy{} = fallback_policy, fallback?, run_fallback) do
    if fallback?.(outcome) do
      do_fallback(outcome, fallback_policy, fallback?, run_fallback)
    else
      outcome
    end
  end

  defp do_fallback(initial_outcome, %FallbackPolicy{} = fallback_policy, fallback?, run_fallback) do
    fallback_policy.alternates
    |> Enum.reduce_while(initial_outcome, fn alternate, current_outcome ->
      alternate_outcome = run_fallback.(alternate, current_outcome)

      if fallback?.(alternate_outcome) do
        {:cont, alternate_outcome}
      else
        {:halt, alternate_outcome}
      end
    end)
    |> maybe_degrade(fallback_policy, fallback?)
  end

  defp maybe_degrade(outcome, %FallbackPolicy{degrade_to: nil}, _fallback?), do: outcome

  defp maybe_degrade(outcome, %FallbackPolicy{degrade_to: degrade_to}, fallback?) do
    if fallback?.(outcome) do
      apply_degrade(degrade_to, outcome)
    else
      outcome
    end
  end

  defp apply_degrade(degrade_to, outcome) when is_function(degrade_to, 1),
    do: degrade_to.(outcome)

  defp apply_degrade(degrade_to, _outcome), do: degrade_to

  defp maybe_sleep(nil, _attempt, _outcome), do: :ok

  defp maybe_sleep(backoff, _attempt, _outcome) when is_integer(backoff),
    do: Process.sleep(backoff)

  defp maybe_sleep(backoff, attempt, _outcome) when is_function(backoff, 1) do
    backoff
    |> apply([attempt])
    |> max(0)
    |> Process.sleep()
  end

  defp maybe_sleep(backoff, attempt, outcome) when is_function(backoff, 2) do
    backoff
    |> apply([attempt, outcome])
    |> max(0)
    |> Process.sleep()
  end

  defp default_retryable?({:retry, _reason}), do: true
  defp default_retryable?({:error, %Error{retryable?: true}}), do: true
  defp default_retryable?(_outcome), do: false

  defp default_fallback?({:ok, _value}), do: false
  defp default_fallback?({:error, _reason}), do: true
  defp default_fallback?({:retry, _reason}), do: true
  defp default_fallback?(_outcome), do: false

  defp default_run_fallback(alternate, _current_outcome) when is_function(alternate, 0) do
    alternate.()
  end

  defp default_run_fallback(alternate, _current_outcome), do: alternate

  defp policy_predicate(nil, _field), do: nil
  defp policy_predicate(policy, field), do: Map.get(policy, field)
end
