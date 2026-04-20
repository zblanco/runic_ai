defmodule RunicAI.Tool.BatchResult do
  @moduledoc """
  Deterministic batch result wrapper for tool execution outputs.
  """

  alias RunicAI.Error
  alias RunicAI.Tool.CallResult

  @enforce_keys [:results, :metadata]
  defstruct [:results, :metadata]

  @type t :: %__MODULE__{
          results: [CallResult.t()],
          metadata: map()
        }

  @spec new([CallResult.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(results, opts \\ []) when is_list(results) and is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_results} <- normalize_results(results),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{results: normalized_results, metadata: metadata}}
    end
  end

  @spec new!([CallResult.t()], keyword()) :: t()
  def new!(results, opts \\ []) do
    case new(results, opts) do
      {:ok, batch_result} -> batch_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = batch_result) do
    new(batch_result.results, metadata: batch_result.metadata)
  end

  defp normalize_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, acc} ->
      case CallResult.validate(result) do
        {:ok, normalized_result} -> {:cont, {:ok, [normalized_result | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_results} -> {:ok, Enum.reverse(normalized_results)}
      error -> error
    end
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool batch metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
