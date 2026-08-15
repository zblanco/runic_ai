defmodule RunicAI.Coding.PatchResult do
  @moduledoc """
  Outcome of applying a structured workspace patch.
  """

  alias RunicAI.Error

  @valid_statuses [:ok, :error, :dry_run, :reconciled]

  @enforce_keys [
    :status,
    :changed_paths,
    :operation_summaries,
    :diagnostics,
    :before_hashes,
    :after_hashes,
    :metadata
  ]
  defstruct [
    :status,
    changed_paths: [],
    operation_summaries: [],
    diagnostics: [],
    before_hashes: %{},
    after_hashes: %{},
    metadata: %{}
  ]

  @type status :: :ok | :error | :dry_run | :reconciled

  @type t :: %__MODULE__{
          status: status(),
          changed_paths: [Path.t()],
          operation_summaries: [map()],
          diagnostics: [map()],
          before_hashes: %{optional(Path.t()) => String.t() | nil},
          after_hashes: %{optional(Path.t()) => String.t() | nil},
          metadata: map()
        }

  @spec new(status(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(status, opts \\ []) when is_list(opts) do
    changed_paths = Keyword.get(opts, :changed_paths, [])
    operation_summaries = Keyword.get(opts, :operation_summaries, [])
    diagnostics = Keyword.get(opts, :diagnostics, [])
    before_hashes = Keyword.get(opts, :before_hashes, %{})
    after_hashes = Keyword.get(opts, :after_hashes, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_status(status),
         :ok <- validate_list(changed_paths, :changed_paths),
         :ok <- validate_list(operation_summaries, :operation_summaries),
         :ok <- validate_list(diagnostics, :diagnostics),
         :ok <- validate_map(before_hashes, :before_hashes),
         :ok <- validate_map(after_hashes, :after_hashes),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         status: status,
         changed_paths: changed_paths,
         operation_summaries: operation_summaries,
         diagnostics: diagnostics,
         before_hashes: before_hashes,
         after_hashes: after_hashes,
         metadata: metadata
       }}
    end
  end

  @spec new!(status(), keyword()) :: t()
  def new!(status, opts \\ []) do
    case new(status, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid patch result status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("patch result #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("patch result #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
