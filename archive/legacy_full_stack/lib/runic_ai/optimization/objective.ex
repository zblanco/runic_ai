defmodule RunicAI.Optimization.Objective do
  @moduledoc """
  Optimization objective used by observational hooks.
  """

  alias RunicAI.Error

  @valid_directions [:maximize, :minimize, :target]

  @enforce_keys [:name, :metric, :direction, :metadata]
  defstruct [:name, :metric, direction: :maximize, target: nil, metadata: %{}]

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          metric: atom() | String.t(),
          direction: :maximize | :minimize | :target,
          target: number() | nil,
          metadata: map()
        }

  @spec new(atom() | String.t(), atom() | String.t(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(name, metric, opts \\ []) when is_list(opts) do
    direction = Keyword.get(opts, :direction, :maximize)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_name(name, :name),
         :ok <- validate_name(metric, :metric),
         :ok <- validate_direction(direction),
         :ok <- validate_target(Keyword.get(opts, :target)),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         name: name,
         metric: metric,
         direction: direction,
         target: Keyword.get(opts, :target),
         metadata: metadata
       }}
    end
  end

  @spec new!(atom() | String.t(), atom() | String.t(), keyword()) :: t()
  def new!(name, metric, opts \\ []) do
    case new(name, metric, opts) do
      {:ok, objective} -> objective
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_name(value, _field) when is_atom(value) or is_binary(value), do: :ok

  defp validate_name(value, field) do
    {:error,
     Error.validation("optimization objective #{field} must be an atom or string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_direction(direction) when direction in @valid_directions, do: :ok

  defp validate_direction(direction) do
    {:error,
     Error.validation("invalid optimization objective direction",
       source: __MODULE__,
       details: %{direction: direction, valid_directions: @valid_directions}
     )}
  end

  defp validate_target(nil), do: :ok
  defp validate_target(value) when is_number(value), do: :ok

  defp validate_target(value) do
    {:error,
     Error.validation("optimization objective target must be numeric or nil",
       source: __MODULE__,
       details: %{target: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("optimization objective #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
