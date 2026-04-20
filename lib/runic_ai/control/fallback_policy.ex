defmodule RunicAI.Control.FallbackPolicy do
  @moduledoc """
  Ordered fallback routes for effect boundaries.
  """

  alias RunicAI.Error

  @enforce_keys [:alternates, :metadata]
  defstruct [:alternates, :fallback_if, :degrade_to, :metadata]

  @type t :: %__MODULE__{
          alternates: [term()],
          fallback_if: (term() -> boolean()) | nil,
          degrade_to: term() | (term() -> term()) | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    alternates = Keyword.get(opts, :alternates, [])
    fallback_if = Keyword.get(opts, :fallback_if)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_alternates(alternates),
         :ok <- validate_fallback_if(fallback_if),
         :ok <- validate_degrade_to(Keyword.get(opts, :degrade_to)),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         alternates: alternates,
         fallback_if: fallback_if,
         degrade_to: Keyword.get(opts, :degrade_to),
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, fallback_policy} -> fallback_policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t() | nil} | {:error, Error.t()}
  def from_input(nil), do: {:ok, nil}
  def from_input(%__MODULE__{} = fallback_policy), do: validate(fallback_policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      alternates: Map.get(input, :alternates, []),
      fallback_if: Map.get(input, :fallback_if),
      degrade_to: Map.get(input, :degrade_to),
      metadata: Map.get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation(
       "expected a Control.FallbackPolicy-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | keyword() | map() | nil) :: t() | nil
  def from_input!(input) do
    case from_input(input) do
      {:ok, fallback_policy} -> fallback_policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = fallback_policy) do
    new(
      alternates: fallback_policy.alternates,
      fallback_if: fallback_policy.fallback_if,
      degrade_to: fallback_policy.degrade_to,
      metadata: fallback_policy.metadata
    )
  end

  defp validate_alternates(alternates) when is_list(alternates), do: :ok

  defp validate_alternates(alternates) do
    {:error,
     Error.validation("fallback alternates must be a list, got: #{inspect(alternates)}",
       source: __MODULE__
     )}
  end

  defp validate_fallback_if(nil), do: :ok
  defp validate_fallback_if(fallback_if) when is_function(fallback_if, 1), do: :ok

  defp validate_fallback_if(fallback_if) do
    {:error,
     Error.validation("fallback fallback_if must be a unary function or nil",
       source: __MODULE__,
       details: %{fallback_if: fallback_if}
     )}
  end

  defp validate_degrade_to(nil), do: :ok
  defp validate_degrade_to(degrade_to) when is_function(degrade_to, 1), do: :ok
  defp validate_degrade_to(_degrade_to), do: :ok

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("fallback policy metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
