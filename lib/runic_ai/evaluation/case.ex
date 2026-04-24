defmodule RunicAI.Evaluation.Case do
  @moduledoc """
  One evaluation or regression case.
  """

  alias RunicAI.Error
  alias RunicAI.Evaluation.Expectation

  @enforce_keys [:id, :expected, :metadata, :tags]
  defstruct [:id, :input, expected: [], metadata: %{}, tags: []]

  @type t :: %__MODULE__{
          id: String.t(),
          input: term(),
          expected: [Expectation.t()],
          metadata: map(),
          tags: [String.t()]
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    id = Keyword.get(opts, :id, default_id())
    metadata = Keyword.get(opts, :metadata, %{})
    tags = Keyword.get(opts, :tags, [])

    with :ok <- validate_id(id),
         {:ok, expected} <- normalize_expectations(Keyword.get(opts, :expected, [])),
         :ok <- validate_metadata(metadata),
         {:ok, normalized_tags} <- normalize_tags(tags) do
      {:ok,
       %__MODULE__{
         id: id,
         input: Keyword.get(opts, :input),
         expected: expected,
         metadata: metadata,
         tags: normalized_tags
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, evaluation_case} -> evaluation_case
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = evaluation_case), do: validate(evaluation_case)
  def from_input(input) when is_list(input), do: new(input)

  def from_input(input) when is_map(input) do
    new(
      id: Map.get(input, :id) || Map.get(input, "id"),
      input: Map.get(input, :input) || Map.get(input, "input"),
      expected: Map.get(input, :expected) || Map.get(input, "expected") || [],
      metadata: Map.get(input, :metadata) || Map.get(input, "metadata") || %{},
      tags: Map.get(input, :tags) || Map.get(input, "tags") || []
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected an Evaluation.Case-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec from_input!(t() | map() | keyword()) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, evaluation_case} -> evaluation_case
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = evaluation_case) do
    new(
      id: evaluation_case.id,
      input: evaluation_case.input,
      expected: evaluation_case.expected,
      metadata: evaluation_case.metadata,
      tags: evaluation_case.tags
    )
  end

  defp normalize_expectations(expectations) when is_list(expectations) do
    expectations
    |> Enum.reduce_while({:ok, []}, fn expectation, {:ok, acc} ->
      case Expectation.from_input(expectation) do
        {:ok, normalized_expectation} -> {:cont, {:ok, [normalized_expectation | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_expectations} -> {:ok, Enum.reverse(normalized_expectations)}
      error -> error
    end
  end

  defp normalize_expectations(other) do
    {:error,
     Error.validation("evaluation case expected must be a list",
       source: __MODULE__,
       details: %{expected: other}
     )}
  end

  defp normalize_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1) do
      {:ok, tags}
    else
      {:error,
       Error.validation("evaluation case tags must be strings",
         source: __MODULE__,
         details: %{tags: tags}
       )}
    end
  end

  defp normalize_tags(other) do
    {:error,
     Error.validation("evaluation case tags must be a list",
       source: __MODULE__,
       details: %{tags: other}
     )}
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("evaluation case id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("evaluation case metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp default_id, do: "case:#{System.unique_integer([:positive])}"
end
