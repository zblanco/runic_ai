defmodule RunicAI.Evaluation.Expectation do
  @moduledoc """
  Typed evaluation expectation and scoring helper.
  """

  alias RunicAI.Error
  alias RunicAI.Evaluation.Result

  @valid_kinds [
    :exact_text,
    :contains_text,
    :tool_called,
    :tool_not_called,
    :review_required,
    :wait_required,
    :custom
  ]

  @enforce_keys [:kind, :weight, :metadata]
  defstruct [:kind, :target, :tolerance, weight: 1.0, metadata: %{}]

  @type t :: %__MODULE__{
          kind: atom(),
          target: term(),
          tolerance: term(),
          weight: number(),
          metadata: map()
        }

  @spec new(atom(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    weight = Keyword.get(opts, :weight, 1.0)

    with :ok <- validate_kind(kind),
         :ok <- validate_weight(weight),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         kind: kind,
         target: Keyword.get(opts, :target),
         tolerance: Keyword.get(opts, :tolerance),
         weight: weight,
         metadata: metadata
       }}
    end
  end

  @spec new!(atom(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, expectation} -> expectation
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | tuple() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = expectation), do: validate(expectation)
  def from_input({kind, target}) when is_atom(kind), do: new(kind, target: target)

  def from_input({kind, target, opts}) when is_atom(kind) and is_list(opts),
    do: new(kind, Keyword.put(opts, :target, target))

  def from_input(input) when is_list(input), do: new(Keyword.fetch!(input, :kind), input)

  def from_input(input) when is_map(input) do
    kind = Map.get(input, :kind) || Map.get(input, "kind")

    new(kind,
      target: Map.get(input, :target) || Map.get(input, "target"),
      tolerance: Map.get(input, :tolerance) || Map.get(input, "tolerance"),
      weight: Map.get(input, :weight) || Map.get(input, "weight") || 1.0,
      metadata: Map.get(input, :metadata) || Map.get(input, "metadata") || %{}
    )
  rescue
    error in KeyError ->
      {:error, Error.validation(Exception.message(error), source: __MODULE__)}
  end

  def from_input(other) do
    {:error,
     Error.validation("expected an Evaluation.Expectation-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = expectation) do
    new(expectation.kind,
      target: expectation.target,
      tolerance: expectation.tolerance,
      weight: expectation.weight,
      metadata: expectation.metadata
    )
  end

  @spec evaluate(Result.t(), t()) :: map()
  def evaluate(%Result{} = result, %__MODULE__{} = expectation) do
    actual = actual_value(result, expectation)

    outcome =
      case expectation.kind do
        :exact_text ->
          compare_exact_text(actual, expectation.target)

        :contains_text ->
          compare_contains_text(actual, expectation.target)

        :tool_called ->
          compare_tool_called(result, expectation.target)

        :tool_not_called ->
          invert(compare_tool_called(result, expectation.target))

        :review_required ->
          compare_boolean(Result.review_required?(result))

        :wait_required ->
          compare_boolean(Result.wait_required?(result))

        :custom ->
          evaluate_custom(result, expectation.target)
      end

    normalize_outcome(expectation, actual, outcome)
  end

  @spec evaluate_all(Result.t(), [t()]) :: {map(), [map()]}
  def evaluate_all(%Result{} = result, expectations) when is_list(expectations) do
    evaluations = Enum.map(expectations, &evaluate(result, &1))
    total_weight = Enum.reduce(evaluations, 0.0, &(&1.weight + &2))
    weighted_score = Enum.reduce(evaluations, 0.0, &(&1.weighted_score + &2))

    overall =
      cond do
        evaluations == [] -> 1.0
        total_weight <= 0 -> 0.0
        true -> weighted_score / total_weight
      end

    failures = Enum.filter(evaluations, &(!&1.passed?))

    {%{
       overall: overall,
       total: length(evaluations),
       passed: Enum.count(evaluations, & &1.passed?),
       evaluations: evaluations
     }, failures}
  end

  defp actual_value(%Result{} = result, %__MODULE__{kind: kind})
       when kind in [:exact_text, :contains_text],
       do: Result.reply_text(result)

  defp actual_value(%Result{} = result, %__MODULE__{kind: :tool_called, target: target}),
    do: Result.tool_called?(result, target)

  defp actual_value(%Result{} = result, %__MODULE__{kind: :tool_not_called, target: target}),
    do: Result.tool_called?(result, target)

  defp actual_value(%Result{} = result, %__MODULE__{kind: :review_required}),
    do: Result.review_required?(result)

  defp actual_value(%Result{} = result, %__MODULE__{kind: :wait_required}),
    do: Result.wait_required?(result)

  defp actual_value(_result, _expectation), do: nil

  defp compare_exact_text(actual, expected) when is_binary(actual) and is_binary(expected),
    do: %{passed?: actual == expected, score: if(actual == expected, do: 1.0, else: 0.0)}

  defp compare_exact_text(_actual, _expected), do: %{passed?: false, score: 0.0}

  defp compare_contains_text(actual, expected) when is_binary(actual) and is_binary(expected) do
    passed? = String.contains?(actual, expected)
    %{passed?: passed?, score: if(passed?, do: 1.0, else: 0.0)}
  end

  defp compare_contains_text(_actual, _expected), do: %{passed?: false, score: 0.0}

  defp compare_tool_called(%Result{} = result, nil),
    do: %{
      passed?: Result.tool_called?(result, nil),
      score: if(Result.tool_called?(result, nil), do: 1.0, else: 0.0)
    }

  defp compare_tool_called(%Result{} = result, tool_name) do
    passed? = Result.tool_called?(result, tool_name)
    %{passed?: passed?, score: if(passed?, do: 1.0, else: 0.0)}
  end

  defp compare_boolean(value) when is_boolean(value),
    do: %{passed?: value, score: if(value, do: 1.0, else: 0.0)}

  defp compare_boolean(_value), do: %{passed?: false, score: 0.0}

  defp invert(%{passed?: passed?, score: score} = outcome) do
    %{outcome | passed?: not passed?, score: if(passed?, do: 0.0, else: max(0.0, 1.0 - score))}
  end

  defp evaluate_custom(%Result{} = result, evaluator) when is_function(evaluator, 1) do
    normalize_custom_outcome(evaluator.(result))
  end

  defp evaluate_custom(_result, evaluator), do: normalize_custom_outcome(evaluator)

  defp normalize_custom_outcome(%{passed?: passed?, score: score} = outcome)
       when is_boolean(passed?) and is_number(score),
       do: Map.take(outcome, [:passed?, :score, :message, :details])

  defp normalize_custom_outcome(score) when is_number(score),
    do: %{passed?: score >= 1.0, score: score}

  defp normalize_custom_outcome(value) when is_boolean(value),
    do: %{passed?: value, score: if(value, do: 1.0, else: 0.0)}

  defp normalize_custom_outcome(_other), do: %{passed?: false, score: 0.0}

  defp normalize_outcome(%__MODULE__{} = expectation, actual, outcome) do
    passed? = Map.get(outcome, :passed?, false)
    score = normalize_score(Map.get(outcome, :score, 0.0))

    %{
      kind: expectation.kind,
      target: expectation.target,
      actual: actual,
      passed?: passed?,
      score: score,
      weight: expectation.weight,
      weighted_score: score * expectation.weight,
      message: Map.get(outcome, :message),
      details: Map.get(outcome, :details, %{})
    }
  end

  defp normalize_score(score) when is_number(score), do: max(0.0, score * 1.0)
  defp normalize_score(_score), do: 0.0

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid evaluation expectation kind",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_weight(weight) when is_number(weight) and weight >= 0, do: :ok

  defp validate_weight(weight) do
    {:error,
     Error.validation("evaluation expectation weight must be a non-negative number",
       source: __MODULE__,
       details: %{weight: weight}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("evaluation expectation metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
