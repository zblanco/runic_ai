defmodule RunicAI.Coding.RLM.PatchPlan do
  @moduledoc "Ordered edit and verification strategy produced by RLM reducers."

  alias RunicAI.Error

  @enforce_keys [:id, :steps, :verification, :write_scope, :metadata]
  defstruct [:id, steps: [], verification: [], write_scope: [], metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          steps: [term()],
          verification: [term()],
          write_scope: [String.t()],
          metadata: map()
        }

  def new(steps, opts \\ []) when is_list(steps) and is_list(opts) do
    value = %__MODULE__{
      id: Keyword.get(opts, :id) || "patch-plan:#{System.unique_integer([:positive])}",
      steps: steps,
      verification: Keyword.get(opts, :verification, []),
      write_scope: Keyword.get(opts, :write_scope, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(value)
  end

  def new!(steps, opts \\ []) do
    case new(steps, opts) do
      {:ok, value} -> value
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def validate(%__MODULE__{} = value) do
    with :ok <- non_empty(value.id, :id),
         :ok <- list(value.steps, :steps),
         :ok <- list(value.verification, :verification),
         :ok <- string_list(value.write_scope, :write_scope),
         :ok <- map(value.metadata, :metadata) do
      {:ok, value}
    end
  end

  defp non_empty(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty(value, field),
    do:
      {:error,
       Error.validation("patch plan #{field} must be a non-empty string",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp list(value, _field) when is_list(value), do: :ok

  defp list(value, field),
    do:
      {:error,
       Error.validation("patch plan #{field} must be a list",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp string_list(values, field) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: :ok, else: list(values, field)
  end

  defp string_list(value, field), do: list(value, field)
  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field),
    do:
      {:error,
       Error.validation("patch plan #{field} must be a map",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}
end
