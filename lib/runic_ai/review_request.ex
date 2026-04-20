defmodule RunicAI.ReviewRequest do
  @moduledoc """
  Typed review request contract for approval and edit gates.
  """

  alias RunicAI.Error

  @valid_options [:approve, :reject, :edit, :cancel]

  @enforce_keys [:kind, :resume_key, :options, :metadata]
  defstruct [:kind, :subject, :checkpoint, :resume_key, :options, details: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          kind: atom(),
          subject: term() | nil,
          checkpoint: atom() | String.t() | nil,
          resume_key: String.t(),
          options: [atom()],
          details: map(),
          metadata: map()
        }

  @spec new(atom(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, opts \\ []) when is_atom(kind) and is_list(opts) do
    checkpoint = Keyword.get(opts, :checkpoint)
    resume_key = Keyword.get(opts, :resume_key, default_resume_key(kind))
    options = Keyword.get(opts, :options, [:approve, :reject, :edit, :cancel])
    details = Keyword.get(opts, :details, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_checkpoint(checkpoint),
         :ok <- validate_resume_key(resume_key),
         :ok <- validate_options(options),
         :ok <- validate_details(details),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         kind: kind,
         subject: Keyword.get(opts, :subject),
         checkpoint: checkpoint,
         resume_key: resume_key,
         options: options,
         details: details,
         metadata: metadata
       }}
    end
  end

  @spec new!(atom(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, review_request} -> review_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = review_request) do
    new(review_request.kind,
      subject: review_request.subject,
      checkpoint: review_request.checkpoint,
      resume_key: review_request.resume_key,
      options: review_request.options,
      details: review_request.details,
      metadata: review_request.metadata
    )
  end

  defp validate_checkpoint(nil), do: :ok
  defp validate_checkpoint(checkpoint) when is_atom(checkpoint) or is_binary(checkpoint), do: :ok

  defp validate_checkpoint(checkpoint) do
    {:error,
     Error.validation(
       "review request checkpoint must be an atom, string, or nil, got: #{inspect(checkpoint)}",
       source: __MODULE__
     )}
  end

  defp validate_resume_key(resume_key) when is_binary(resume_key) and resume_key != "", do: :ok

  defp validate_resume_key(resume_key) do
    {:error,
     Error.validation(
       "review request resume_key must be a non-empty string, got: #{inspect(resume_key)}",
       source: __MODULE__
     )}
  end

  defp validate_options(options) when is_list(options) do
    if Enum.all?(options, &(&1 in @valid_options)) do
      :ok
    else
      {:error,
       Error.validation("review request options must be valid review actions",
         source: __MODULE__,
         details: %{options: options, valid_options: @valid_options}
       )}
    end
  end

  defp validate_options(options) do
    {:error,
     Error.validation("review request options must be a list, got: #{inspect(options)}",
       source: __MODULE__
     )}
  end

  defp validate_details(details) when is_map(details), do: :ok

  defp validate_details(details) do
    {:error,
     Error.validation("review request details must be a map, got: #{inspect(details)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("review request metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp default_resume_key(kind) do
    "review:#{kind}:#{System.unique_integer([:positive])}"
  end
end
