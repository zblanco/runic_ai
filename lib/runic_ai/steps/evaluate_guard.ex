defmodule RunicAI.Steps.EvaluateGuard do
  @moduledoc """
  Evaluate one guard request with a plain function or module callback.
  """

  require Runic

  alias RunicAI.Control.GuardDecision
  alias RunicAI.Control.GuardRequest
  alias RunicAI.Error

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :evaluate_guard)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %GuardRequest{} = guard_request ->
        evaluate!(guard_request, options)
      end,
      name: name
    )
  end

  @spec evaluate(GuardRequest.t(), keyword()) :: {:ok, GuardDecision.t()} | {:error, Error.t()}
  def evaluate(%GuardRequest{} = guard_request, opts \\ []) do
    with {:ok, guard_request} <- GuardRequest.validate(guard_request) do
      guard_request
      |> run_evaluator(Keyword.get(opts, :evaluator))
      |> normalize_decision()
    end
  end

  @spec evaluate!(GuardRequest.t(), keyword()) :: GuardDecision.t()
  def evaluate!(%GuardRequest{} = guard_request, opts \\ []) do
    case evaluate(guard_request, opts) do
      {:ok, guard_decision} -> guard_decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp run_evaluator(%GuardRequest{} = _guard_request, nil), do: :allow

  defp run_evaluator(%GuardRequest{} = guard_request, evaluator) when is_function(evaluator, 1) do
    evaluator.(guard_request)
  end

  defp run_evaluator(%GuardRequest{} = guard_request, evaluator) when is_atom(evaluator) do
    apply(evaluator, :evaluate, [guard_request])
  end

  defp run_evaluator(%GuardRequest{} = guard_request, {module, function})
       when is_atom(module) and is_atom(function) do
    apply(module, function, [guard_request])
  end

  defp run_evaluator(%GuardRequest{} = guard_request, {module, function, extra_args})
       when is_atom(module) and is_atom(function) and is_list(extra_args) do
    apply(module, function, [guard_request | extra_args])
  end

  defp normalize_decision(%GuardDecision{} = guard_decision),
    do: GuardDecision.validate(guard_decision)

  defp normalize_decision(:allow), do: GuardDecision.allow(:allow)
  defp normalize_decision(:deny), do: GuardDecision.deny(:deny)
  defp normalize_decision(:review), do: GuardDecision.review(:review)
  defp normalize_decision(:wait), do: GuardDecision.wait(:wait)
  defp normalize_decision(true), do: GuardDecision.allow(:allow)
  defp normalize_decision(false), do: GuardDecision.deny(:deny)
  defp normalize_decision({:allow, reason}), do: GuardDecision.allow(reason)
  defp normalize_decision({:deny, reason}), do: GuardDecision.deny(reason)
  defp normalize_decision({:review, reason}), do: GuardDecision.review(reason)
  defp normalize_decision({:wait, reason}), do: GuardDecision.wait(reason)

  defp normalize_decision({:rewrite, replacement}),
    do: GuardDecision.rewrite(:rewrite, replacement)

  defp normalize_decision({:rewrite, reason, replacement}),
    do: GuardDecision.rewrite(reason, replacement)

  defp normalize_decision(other) do
    {:error,
     Error.validation("unsupported guard evaluator result: #{inspect(other)}", source: __MODULE__)}
  end
end
