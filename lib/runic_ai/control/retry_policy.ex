defmodule RunicAI.Control.RetryPolicy do
  @moduledoc """
  Declarative retry policy for effect boundaries.
  """

  alias RunicAI.Error

  @valid_on_exhausted [:error, :halt]

  @enforce_keys [:max_attempts, :on_exhausted, :metadata]
  defstruct [:max_attempts, :backoff, :retry_if, :on_exhausted, :metadata]

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff: non_neg_integer() | (non_neg_integer() -> non_neg_integer()) | nil,
          retry_if: (term() -> boolean()) | nil,
          on_exhausted: :error | :halt,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    max_attempts = Keyword.get(opts, :max_attempts, 1)
    backoff = Keyword.get(opts, :backoff)
    retry_if = Keyword.get(opts, :retry_if)
    on_exhausted = Keyword.get(opts, :on_exhausted, :error)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_max_attempts(max_attempts),
         :ok <- validate_backoff(backoff),
         :ok <- validate_retry_if(retry_if),
         :ok <- validate_on_exhausted(on_exhausted),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         max_attempts: max_attempts,
         backoff: backoff,
         retry_if: retry_if,
         on_exhausted: on_exhausted,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, retry_policy} -> retry_policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t() | nil} | {:error, Error.t()}
  def from_input(nil), do: {:ok, nil}
  def from_input(%__MODULE__{} = retry_policy), do: validate(retry_policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      max_attempts: Map.get(input, :max_attempts, 1),
      backoff: Map.get(input, :backoff),
      retry_if: Map.get(input, :retry_if),
      on_exhausted: Map.get(input, :on_exhausted, :error),
      metadata: Map.get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Control.RetryPolicy-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | keyword() | map() | nil) :: t() | nil
  def from_input!(input) do
    case from_input(input) do
      {:ok, retry_policy} -> retry_policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = retry_policy) do
    new(
      max_attempts: retry_policy.max_attempts,
      backoff: retry_policy.backoff,
      retry_if: retry_policy.retry_if,
      on_exhausted: retry_policy.on_exhausted,
      metadata: retry_policy.metadata
    )
  end

  defp validate_max_attempts(max_attempts) when is_integer(max_attempts) and max_attempts > 0,
    do: :ok

  defp validate_max_attempts(max_attempts) do
    {:error,
     Error.validation("retry max_attempts must be a positive integer",
       source: __MODULE__,
       details: %{max_attempts: max_attempts}
     )}
  end

  defp validate_backoff(nil), do: :ok
  defp validate_backoff(backoff) when is_integer(backoff) and backoff >= 0, do: :ok
  defp validate_backoff(backoff) when is_function(backoff, 1), do: :ok

  defp validate_backoff(backoff) do
    {:error,
     Error.validation("retry backoff must be nil, a non-negative integer, or a unary function",
       source: __MODULE__,
       details: %{backoff: backoff}
     )}
  end

  defp validate_retry_if(nil), do: :ok
  defp validate_retry_if(retry_if) when is_function(retry_if, 1), do: :ok

  defp validate_retry_if(retry_if) do
    {:error,
     Error.validation("retry retry_if must be a unary function or nil",
       source: __MODULE__,
       details: %{retry_if: retry_if}
     )}
  end

  defp validate_on_exhausted(on_exhausted) when on_exhausted in @valid_on_exhausted, do: :ok

  defp validate_on_exhausted(on_exhausted) do
    {:error,
     Error.validation("invalid retry on_exhausted value: #{inspect(on_exhausted)}",
       source: __MODULE__,
       details: %{on_exhausted: on_exhausted, valid_values: @valid_on_exhausted}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("retry policy metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
