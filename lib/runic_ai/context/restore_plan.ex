defmodule RunicAI.Context.RestorePlan do
  @moduledoc """
  Explicit plan for restoring context into an active runtime session.
  """

  alias RunicAI.Context.Ref
  alias RunicAI.Error

  @valid_modes [:none, :latest, :selective]

  @enforce_keys [:mode, :refs, :metadata]
  defstruct mode: :latest, refs: [], focus: nil, metadata: %{}

  @type t :: %__MODULE__{
          mode: :none | :latest | :selective,
          refs: [Ref.t() | String.t()],
          focus: term(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :latest)
    refs = Keyword.get(opts, :refs, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_mode(mode),
         :ok <- validate_list(refs, :refs),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{mode: mode, refs: refs, focus: Keyword.get(opts, :focus), metadata: metadata}}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, plan} -> plan
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_mode(mode) when mode in @valid_modes, do: :ok

  defp validate_mode(mode) do
    {:error,
     Error.validation("invalid context restore mode",
       source: __MODULE__,
       details: %{mode: mode, valid_modes: @valid_modes}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("context restore #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("context restore #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
