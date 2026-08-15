defmodule RunicAI.Context.HorizonPolicy do
  @moduledoc """
  Policy for checkpointing and restoring long-horizon context.
  """

  alias RunicAI.Error

  @valid_checkpoint_modes [:none, :on_turn, :on_pause, :manual]
  @valid_restore_modes [:none, :latest, :selective]

  @enforce_keys [:checkpoint_mode, :restore_mode, :metadata]
  defstruct checkpoint_mode: :on_pause,
            restore_mode: :latest,
            max_checkpoints: 32,
            expand_refs?: false,
            metadata: %{}

  @type t :: %__MODULE__{
          checkpoint_mode: :none | :on_turn | :on_pause | :manual,
          restore_mode: :none | :latest | :selective,
          max_checkpoints: pos_integer(),
          expand_refs?: boolean(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    checkpoint_mode = Keyword.get(opts, :checkpoint_mode, :on_pause)
    restore_mode = Keyword.get(opts, :restore_mode, :latest)
    max_checkpoints = Keyword.get(opts, :max_checkpoints, 32)
    expand_refs? = Keyword.get(opts, :expand_refs?, false)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_member(checkpoint_mode, @valid_checkpoint_modes, :checkpoint_mode),
         :ok <- validate_member(restore_mode, @valid_restore_modes, :restore_mode),
         :ok <- validate_positive_integer(max_checkpoints, :max_checkpoints),
         :ok <- validate_boolean(expand_refs?, :expand_refs?),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         checkpoint_mode: checkpoint_mode,
         restore_mode: restore_mode,
         max_checkpoints: max_checkpoints,
         expand_refs?: expand_refs?,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_member(value, valid, field) do
    if value in valid do
      :ok
    else
      {:error,
       Error.validation("invalid horizon policy #{field}",
         source: __MODULE__,
         details: %{field: field, value: value, valid: valid}
       )}
    end
  end

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(value, field) do
    {:error,
     Error.validation("horizon policy #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("horizon policy #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("horizon policy #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
