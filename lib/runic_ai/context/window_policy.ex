defmodule RunicAI.Context.WindowPolicy do
  @moduledoc """
  Declarative input-window and relief preferences for context assembly.
  """

  alias RunicAI.Error

  @valid_relief [:compact, :handoff, :retrieve, :review]

  @enforce_keys [
    :max_input_tokens,
    :reserve_output_tokens,
    :soft_pressure_tokens,
    :hard_pressure_tokens,
    :fresh_tail_messages,
    :fresh_tail_tokens,
    :preferred_relief,
    :metadata
  ]
  defstruct [
    :max_input_tokens,
    :reserve_output_tokens,
    :soft_pressure_tokens,
    :hard_pressure_tokens,
    :fresh_tail_messages,
    :fresh_tail_tokens,
    :preferred_relief,
    :metadata
  ]

  @type relief :: :compact | :handoff | :retrieve | :review

  @type t :: %__MODULE__{
          max_input_tokens: pos_integer(),
          reserve_output_tokens: non_neg_integer(),
          soft_pressure_tokens: pos_integer(),
          hard_pressure_tokens: pos_integer(),
          fresh_tail_messages: pos_integer(),
          fresh_tail_tokens: pos_integer(),
          preferred_relief: relief(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    max_input_tokens = Keyword.get(opts, :max_input_tokens, 4_000)
    reserve_output_tokens = Keyword.get(opts, :reserve_output_tokens, 800)
    soft_pressure_tokens = Keyword.get(opts, :soft_pressure_tokens, 3_000)
    hard_pressure_tokens = Keyword.get(opts, :hard_pressure_tokens, 3_600)
    fresh_tail_messages = Keyword.get(opts, :fresh_tail_messages, 8)
    fresh_tail_tokens = Keyword.get(opts, :fresh_tail_tokens, 1_200)
    preferred_relief = Keyword.get(opts, :preferred_relief, :compact)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_positive(:max_input_tokens, max_input_tokens),
         :ok <- validate_non_negative(:reserve_output_tokens, reserve_output_tokens),
         :ok <- validate_positive(:soft_pressure_tokens, soft_pressure_tokens),
         :ok <- validate_positive(:hard_pressure_tokens, hard_pressure_tokens),
         :ok <- validate_positive(:fresh_tail_messages, fresh_tail_messages),
         :ok <- validate_positive(:fresh_tail_tokens, fresh_tail_tokens),
         :ok <- validate_relief(preferred_relief),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         max_input_tokens: max_input_tokens,
         reserve_output_tokens: reserve_output_tokens,
         soft_pressure_tokens: soft_pressure_tokens,
         hard_pressure_tokens: hard_pressure_tokens,
         fresh_tail_messages: fresh_tail_messages,
         fresh_tail_tokens: fresh_tail_tokens,
         preferred_relief: preferred_relief,
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

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      max_input_tokens: policy.max_input_tokens,
      reserve_output_tokens: policy.reserve_output_tokens,
      soft_pressure_tokens: policy.soft_pressure_tokens,
      hard_pressure_tokens: policy.hard_pressure_tokens,
      fresh_tail_messages: policy.fresh_tail_messages,
      fresh_tail_tokens: policy.fresh_tail_tokens,
      preferred_relief: policy.preferred_relief,
      metadata: policy.metadata
    )
  end

  defp validate_positive(_field, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive(field, value) do
    {:error,
     Error.validation("context window policy #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_non_negative(_field, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_negative(field, value) do
    {:error,
     Error.validation("context window policy #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_relief(relief) when relief in @valid_relief, do: :ok

  defp validate_relief(relief) do
    {:error,
     Error.validation("invalid context relief strategy: #{inspect(relief)}",
       source: __MODULE__,
       details: %{relief: relief, valid_relief: @valid_relief}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context window policy metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
