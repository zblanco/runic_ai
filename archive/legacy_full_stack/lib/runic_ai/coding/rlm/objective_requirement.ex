defmodule RunicAI.Coding.RLM.ObjectiveRequirement do
  @moduledoc """
  A semantic requirement extracted from a coding objective.

  Requirements are intentionally language- and framework-agnostic. They describe
  what must be true, which evidence should prove it, and how a verifier should
  decide whether an implementation attempt satisfied it.
  """

  alias RunicAI.Error

  @enforce_keys [
    :id,
    :kind,
    :description,
    :required?,
    :evidence_needed,
    :acceptance_criteria,
    :metadata
  ]
  defstruct [
    :id,
    :kind,
    :description,
    required?: true,
    evidence_needed: [],
    acceptance_criteria: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: String.t(),
          description: String.t(),
          required?: boolean(),
          evidence_needed: [String.t()],
          acceptance_criteria: [String.t()],
          metadata: map()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    requirement = %__MODULE__{
      id: string_value(input, :id) || generated_id(input),
      kind: string_value(input, :kind) || "requirement",
      description:
        string_value(input, :description) || string_value(input, :requirement) ||
          string_value(input, :summary),
      required?: boolean_value(input, :required?, boolean_value(input, :required, true)),
      evidence_needed:
        string_list(
          value(
            input,
            :evidence_needed,
            value(input, :evidence, value(input, :evidence_types, []))
          )
        ),
      acceptance_criteria:
        string_list(
          value(input, :acceptance_criteria, value(input, :criteria, value(input, :checks, [])))
        ),
      metadata: normalize_map(value(input, :metadata, %{}))
    }

    validate(requirement)
  end

  def new(input) do
    {:error,
     Error.validation("objective requirement must be a map or keyword list",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec new!(keyword() | map()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, requirement} -> requirement
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = requirement), do: validate(requirement)
  def from_input(input), do: new(input)

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = requirement) do
    with :ok <- non_empty_string(requirement.id, :id),
         :ok <- non_empty_string(requirement.kind, :kind),
         :ok <- non_empty_string(requirement.description, :description),
         :ok <- boolean(requirement.required?, :required?),
         :ok <- string_list_field(requirement.evidence_needed, :evidence_needed),
         :ok <- string_list_field(requirement.acceptance_criteria, :acceptance_criteria),
         :ok <- map(requirement.metadata, :metadata) do
      {:ok, requirement}
    end
  end

  defp generated_id(input) do
    basis =
      string_value(input, :description) || string_value(input, :requirement) ||
        inspect(input, limit: 20)

    "requirement:#{:erlang.phash2(basis)}"
  end

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("objective requirement #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp boolean(value, _field) when is_boolean(value), do: :ok

  defp boolean(value, field) do
    {:error,
     Error.validation("objective requirement #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp string_list_field(values, _field) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      :ok
    else
      {:error,
       Error.validation("objective requirement list field must contain strings",
         source: __MODULE__,
         details: %{values: values}
       )}
    end
  end

  defp string_list_field(value, field) do
    {:error,
     Error.validation("objective requirement #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field) do
    {:error,
     Error.validation("objective requirement #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&stringify/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp string_list(value) when is_binary(value), do: [value]
  defp string_list(_value), do: []

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: inspect(value)

  defp string_value(map, key) do
    case value(map, key) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      _value -> nil
    end
  end

  defp boolean_value(map, key, default) do
    case value(map, key, default) do
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      _value -> default
    end
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
