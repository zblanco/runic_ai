defmodule RunicAI.Wait do
  @moduledoc """
  Typed wait contract for explicit workflow suspension points.
  """

  alias RunicAI.Error

  @enforce_keys [:kind, :resume_key, :metadata]
  defstruct [:kind, :reason, :resume_key, :until, :payload, details: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          kind: atom(),
          reason: atom() | String.t() | nil,
          resume_key: String.t(),
          until: DateTime.t() | nil,
          payload: term(),
          details: map(),
          metadata: map()
        }

  @spec new(atom(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, opts \\ []) when is_atom(kind) and is_list(opts) do
    reason = Keyword.get(opts, :reason)
    resume_key = Keyword.get(opts, :resume_key, default_resume_key(kind))
    wait_until = Keyword.get(opts, :until)
    details = Keyword.get(opts, :details, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_reason(reason),
         :ok <- validate_resume_key(resume_key),
         :ok <- validate_until(wait_until),
         :ok <- validate_details(details),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         kind: kind,
         reason: reason,
         resume_key: resume_key,
         until: wait_until,
         payload: Keyword.get(opts, :payload),
         details: details,
         metadata: metadata
       }}
    end
  end

  @spec new!(atom(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, wait} -> wait
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = wait) do
    new(wait.kind,
      reason: wait.reason,
      resume_key: wait.resume_key,
      until: wait.until,
      payload: wait.payload,
      details: wait.details,
      metadata: wait.metadata
    )
  end

  defp validate_reason(nil), do: :ok
  defp validate_reason(reason) when is_atom(reason) or is_binary(reason), do: :ok

  defp validate_reason(reason) do
    {:error,
     Error.validation("wait reason must be an atom, string, or nil, got: #{inspect(reason)}",
       source: __MODULE__
     )}
  end

  defp validate_resume_key(resume_key) when is_binary(resume_key) and resume_key != "", do: :ok

  defp validate_resume_key(resume_key) do
    {:error,
     Error.validation("wait resume_key must be a non-empty string, got: #{inspect(resume_key)}",
       source: __MODULE__
     )}
  end

  defp validate_until(nil), do: :ok
  defp validate_until(%DateTime{}), do: :ok

  defp validate_until(wait_until) do
    {:error,
     Error.validation("wait until must be a DateTime or nil, got: #{inspect(wait_until)}",
       source: __MODULE__
     )}
  end

  defp validate_details(details) when is_map(details), do: :ok

  defp validate_details(details) do
    {:error,
     Error.validation("wait details must be a map, got: #{inspect(details)}", source: __MODULE__)}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("wait metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp default_resume_key(kind) do
    "wait:#{kind}:#{System.unique_integer([:positive])}"
  end
end
