defmodule RunicAI.Coding.RLM.ContractFact do
  @moduledoc "API, behavior, or test contract discovered during RLM coding work."

  alias RunicAI.Error

  @enforce_keys [:id, :subject, :fact, :evidence, :metadata]
  defstruct [:id, :subject, :fact, evidence: [], metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          subject: String.t(),
          fact: String.t(),
          evidence: [term()],
          metadata: map()
        }

  def new(subject, fact, opts \\ [])
      when is_binary(subject) and is_binary(fact) and is_list(opts) do
    value = %__MODULE__{
      id: Keyword.get(opts, :id) || "contract:#{System.unique_integer([:positive])}",
      subject: subject,
      fact: fact,
      evidence: Keyword.get(opts, :evidence, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(value)
  end

  def new!(subject, fact, opts \\ []) do
    case new(subject, fact, opts) do
      {:ok, value} -> value
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def validate(%__MODULE__{} = value) do
    with :ok <- non_empty(value.id, :id),
         :ok <- non_empty(value.subject, :subject),
         :ok <- non_empty(value.fact, :fact),
         :ok <- list(value.evidence, :evidence),
         :ok <- map(value.metadata, :metadata) do
      {:ok, value}
    end
  end

  defp non_empty(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty(value, field),
    do:
      {:error,
       Error.validation("contract #{field} must be a non-empty string",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp list(value, _field) when is_list(value), do: :ok

  defp list(value, field),
    do:
      {:error,
       Error.validation("contract #{field} must be a list",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field),
    do:
      {:error,
       Error.validation("contract #{field} must be a map",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}
end
