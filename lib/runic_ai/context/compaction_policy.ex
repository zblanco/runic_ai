defmodule RunicAI.Context.CompactionPolicy do
  @moduledoc """
  Declarative compaction settings for summary-backed context control.
  """

  alias RunicAI.Error

  @valid_strategies [:summary_dag, :rolling_summary, :none]
  @valid_fallbacks [:keep_tail, :handoff, :review]

  @enforce_keys [
    :strategy,
    :leaf_target_tokens,
    :condensed_target_tokens,
    :max_depth_per_pass,
    :summary_style,
    :fallback_mode,
    :metadata
  ]
  defstruct [
    :strategy,
    :leaf_target_tokens,
    :condensed_target_tokens,
    :max_depth_per_pass,
    :summary_style,
    :salience_prompt,
    :fallback_mode,
    :metadata
  ]

  @type strategy :: :summary_dag | :rolling_summary | :none

  @type t :: %__MODULE__{
          strategy: strategy(),
          leaf_target_tokens: pos_integer(),
          condensed_target_tokens: pos_integer(),
          max_depth_per_pass: non_neg_integer(),
          summary_style: atom() | String.t(),
          salience_prompt: String.t() | nil,
          fallback_mode: :keep_tail | :handoff | :review,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    strategy = Keyword.get(opts, :strategy, :summary_dag)
    leaf_target_tokens = Keyword.get(opts, :leaf_target_tokens, 400)
    condensed_target_tokens = Keyword.get(opts, :condensed_target_tokens, 250)
    max_depth_per_pass = Keyword.get(opts, :max_depth_per_pass, 1)
    summary_style = Keyword.get(opts, :summary_style, :salient_outline)
    salience_prompt = Keyword.get(opts, :salience_prompt)
    fallback_mode = Keyword.get(opts, :fallback_mode, :keep_tail)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_strategy(strategy),
         :ok <- validate_positive(:leaf_target_tokens, leaf_target_tokens),
         :ok <- validate_positive(:condensed_target_tokens, condensed_target_tokens),
         :ok <- validate_non_negative(:max_depth_per_pass, max_depth_per_pass),
         :ok <- validate_summary_style(summary_style),
         :ok <- validate_optional_string(:salience_prompt, salience_prompt),
         :ok <- validate_fallback_mode(fallback_mode),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         strategy: strategy,
         leaf_target_tokens: leaf_target_tokens,
         condensed_target_tokens: condensed_target_tokens,
         max_depth_per_pass: max_depth_per_pass,
         summary_style: summary_style,
         salience_prompt: salience_prompt,
         fallback_mode: fallback_mode,
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
      strategy: policy.strategy,
      leaf_target_tokens: policy.leaf_target_tokens,
      condensed_target_tokens: policy.condensed_target_tokens,
      max_depth_per_pass: policy.max_depth_per_pass,
      summary_style: policy.summary_style,
      salience_prompt: policy.salience_prompt,
      fallback_mode: policy.fallback_mode,
      metadata: policy.metadata
    )
  end

  defp validate_strategy(strategy) when strategy in @valid_strategies, do: :ok

  defp validate_strategy(strategy) do
    {:error,
     Error.validation("invalid context compaction strategy: #{inspect(strategy)}",
       source: __MODULE__,
       details: %{strategy: strategy, valid_strategies: @valid_strategies}
     )}
  end

  defp validate_positive(_field, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive(field, value) do
    {:error,
     Error.validation("context compaction #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_non_negative(_field, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_negative(field, value) do
    {:error,
     Error.validation("context compaction #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_summary_style(style) when is_atom(style) or is_binary(style), do: :ok

  defp validate_summary_style(style) do
    {:error,
     Error.validation("context compaction summary_style must be an atom or string",
       source: __MODULE__,
       details: %{summary_style: style}
     )}
  end

  defp validate_optional_string(_field, nil), do: :ok
  defp validate_optional_string(_field, value) when is_binary(value), do: :ok

  defp validate_optional_string(field, value) do
    {:error,
     Error.validation("context compaction #{field} must be a string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_fallback_mode(mode) when mode in @valid_fallbacks, do: :ok

  defp validate_fallback_mode(mode) do
    {:error,
     Error.validation("invalid context compaction fallback_mode: #{inspect(mode)}",
       source: __MODULE__,
       details: %{fallback_mode: mode, valid_fallbacks: @valid_fallbacks}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context compaction metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
