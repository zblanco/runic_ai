defmodule RunicAI.Context.HandoffRequest do
  @moduledoc """
  Goal-conditioned request for building a handoff artifact.
  """

  alias RunicAI.Error

  @enforce_keys [:goal, :audience, :max_seed_tokens, :include_refs?, :metadata]
  defstruct [:goal, :audience, :max_seed_tokens, :include_refs?, :style_prompt, :metadata]

  @type t :: %__MODULE__{
          goal: String.t(),
          audience: String.t(),
          max_seed_tokens: pos_integer(),
          include_refs?: boolean(),
          style_prompt: String.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    goal = Keyword.get(opts, :goal, "")
    audience = Keyword.get(opts, :audience, "next_thread")
    max_seed_tokens = Keyword.get(opts, :max_seed_tokens, 1_200)
    include_refs? = Keyword.get(opts, :include_refs?, true)
    style_prompt = Keyword.get(opts, :style_prompt)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_string(:goal, goal),
         :ok <- validate_string(:audience, audience),
         :ok <- validate_positive(:max_seed_tokens, max_seed_tokens),
         :ok <- validate_boolean(:include_refs?, include_refs?),
         :ok <- validate_optional_string(:style_prompt, style_prompt),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         goal: goal,
         audience: audience,
         max_seed_tokens: max_seed_tokens,
         include_refs?: include_refs?,
         style_prompt: style_prompt,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, request} -> request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = request) do
    new(
      goal: request.goal,
      audience: request.audience,
      max_seed_tokens: request.max_seed_tokens,
      include_refs?: request.include_refs?,
      style_prompt: request.style_prompt,
      metadata: request.metadata
    )
  end

  defp validate_string(_field, value) when is_binary(value) and value != "", do: :ok

  defp validate_string(field, value) do
    {:error,
     Error.validation("handoff request #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_string(_field, nil), do: :ok
  defp validate_optional_string(_field, value) when is_binary(value), do: :ok

  defp validate_optional_string(field, value) do
    {:error,
     Error.validation("handoff request #{field} must be a string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_positive(_field, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive(field, value) do
    {:error,
     Error.validation("handoff request #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_boolean(_field, value) when is_boolean(value), do: :ok

  defp validate_boolean(field, value) do
    {:error,
     Error.validation("handoff request #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("handoff request metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
