defmodule RunicAI.Coding.RLM.VerificationObservation do
  @moduledoc "Normalized verification result from commands or verifier children."

  alias RunicAI.Error

  @valid_statuses [:pass, :fail, :timeout, :blocked, :skipped, :flaky]

  @enforce_keys [:id, :status, :command, :output_preview, :metadata]
  defstruct [:id, :status, :command, output_preview: "", metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          status: atom(),
          command: [String.t()] | String.t() | nil,
          output_preview: String.t(),
          metadata: map()
        }

  def new(status, opts \\ []) when is_list(opts) do
    value = %__MODULE__{
      id: Keyword.get(opts, :id) || "verification:#{System.unique_integer([:positive])}",
      status: normalize_status(status),
      command: Keyword.get(opts, :command),
      output_preview: Keyword.get(opts, :output_preview, ""),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(value)
  end

  def new!(status, opts \\ []) do
    case new(status, opts) do
      {:ok, value} -> value
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def validate(%__MODULE__{} = value) do
    with :ok <- non_empty(value.id, :id),
         :ok <- status(value.status),
         :ok <- output(value.output_preview),
         :ok <- map(value.metadata, :metadata) do
      {:ok, value}
    end
  end

  defp normalize_status(value) when value in @valid_statuses, do: value
  defp normalize_status("pass"), do: :pass
  defp normalize_status("fail"), do: :fail
  defp normalize_status("timeout"), do: :timeout
  defp normalize_status("blocked"), do: :blocked
  defp normalize_status("skipped"), do: :skipped
  defp normalize_status("flaky"), do: :flaky
  defp normalize_status(value), do: value

  defp non_empty(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty(value, field),
    do:
      {:error,
       Error.validation("verification #{field} must be a non-empty string",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp status(value) when value in @valid_statuses, do: :ok

  defp status(value),
    do:
      {:error,
       Error.validation("invalid verification status",
         source: __MODULE__,
         details: %{status: value}
       )}

  defp output(value) when is_binary(value), do: :ok

  defp output(value),
    do:
      {:error,
       Error.validation("verification output_preview must be a string",
         source: __MODULE__,
         details: %{output_preview: value}
       )}

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field),
    do:
      {:error,
       Error.validation("verification #{field} must be a map",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}
end
