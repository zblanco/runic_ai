defmodule RunicAI.Integrated.PendingWork do
  @moduledoc """
  Workflow-owned representation of the current unit of work for one agent lane.
  """

  alias RunicAI.Error
  alias RunicAI.ReviewRequest
  alias RunicAI.Wait

  @valid_kinds [:turn, :tool_batch, :review, :wait, :resume, :handoff, :spawn]

  @enforce_keys [:kind, :metadata]
  defstruct [:kind, :request, :checkpoint, :resume_key, metadata: %{}]

  @type kind :: :turn | :tool_batch | :review | :wait | :resume | :handoff | :spawn

  @type t :: %__MODULE__{
          kind: kind(),
          request: term(),
          checkpoint: atom() | String.t() | nil,
          resume_key: String.t() | nil,
          metadata: map()
        }

  @spec new(kind() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, opts \\ []) when is_list(opts) do
    checkpoint = Keyword.get(opts, :checkpoint)
    metadata = Keyword.get(opts, :metadata, %{})
    request = Keyword.get(opts, :request)

    with {:ok, normalized_kind} <- normalize_kind(kind),
         :ok <- validate_checkpoint(checkpoint),
         :ok <- validate_request(request),
         {:ok, resume_key} <- normalize_resume_key(Keyword.get(opts, :resume_key), request),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         kind: normalized_kind,
         request: request,
         checkpoint: checkpoint,
         resume_key: resume_key,
         metadata: metadata
       }}
    end
  end

  @spec new!(kind() | String.t(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, pending_work} -> pending_work
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = pending_work) do
    new(pending_work.kind,
      request: pending_work.request,
      checkpoint: pending_work.checkpoint,
      resume_key: pending_work.resume_key,
      metadata: pending_work.metadata
    )
  end

  defp normalize_kind(kind) when kind in @valid_kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    case Enum.find(@valid_kinds, &(Atom.to_string(&1) == kind)) do
      nil ->
        {:error,
         Error.validation("invalid integrated pending_work kind: #{inspect(kind)}",
           source: __MODULE__,
           details: %{kind: kind, valid_kinds: @valid_kinds}
         )}

      normalized_kind ->
        {:ok, normalized_kind}
    end
  end

  defp normalize_kind(kind) do
    {:error,
     Error.validation("invalid integrated pending_work kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_checkpoint(nil), do: :ok
  defp validate_checkpoint(checkpoint) when is_atom(checkpoint) or is_binary(checkpoint), do: :ok

  defp validate_checkpoint(checkpoint) do
    {:error,
     Error.validation("integrated pending_work checkpoint must be an atom, string, or nil",
       source: __MODULE__,
       details: %{checkpoint: checkpoint}
     )}
  end

  defp validate_request(%ReviewRequest{} = request) do
    case ReviewRequest.validate(request) do
      {:ok, _request} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp validate_request(%Wait{} = request) do
    case Wait.validate(request) do
      {:ok, _request} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp validate_request(_request), do: :ok

  defp normalize_resume_key(nil, %ReviewRequest{resume_key: resume_key}), do: {:ok, resume_key}
  defp normalize_resume_key(nil, %Wait{resume_key: resume_key}), do: {:ok, resume_key}
  defp normalize_resume_key(nil, _request), do: {:ok, nil}

  defp normalize_resume_key(resume_key, _request) when is_binary(resume_key) and resume_key != "",
    do: {:ok, resume_key}

  defp normalize_resume_key(resume_key, _request) do
    {:error,
     Error.validation("integrated pending_work resume_key must be a non-empty string or nil",
       source: __MODULE__,
       details: %{resume_key: resume_key}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("integrated pending_work metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
