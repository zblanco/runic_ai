defmodule RunicAI.Assistant.RLM.ComponentBlueprint do
  @moduledoc """
  Data contract for one generated assistant workflow component.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.ComponentCatalog

  @enforce_keys [:id, :type]
  @derive Jason.Encoder
  defstruct [
    :id,
    :type,
    params: %{},
    inputs: [],
    outputs: ["output"],
    policy: %{},
    provenance: [],
    metadata: %{}
  ]

  @type type ::
          :source_discovery
          | :source_splitter
          | :source_materializer
          | :tabular_parser
          | :llm_map
          | :record_map
          | :record_group
          | :document_compare
          | :llm_leaf
          | :report_composer
          | :blueprint_transform
          | :blueprint_reduce
          | :artifact_writer
          | :objective_scorecard
          | :budget_ledger
          | :verification

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          params: map(),
          inputs: [String.t()],
          outputs: [String.t()],
          policy: map(),
          provenance: [term()],
          metadata: map()
        }

  @spec new(String.t(), type() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, type, opts \\ []) when is_list(opts) do
    with :ok <- validate_id(id),
         {:ok, type} <- normalize_type(type),
         :ok <- validate_map(Keyword.get(opts, :params, %{}), :params),
         :ok <- validate_list(Keyword.get(opts, :inputs, []), :inputs),
         :ok <- validate_list(Keyword.get(opts, :outputs, ["output"]), :outputs),
         :ok <- validate_map(Keyword.get(opts, :policy, %{}), :policy),
         :ok <- validate_list(Keyword.get(opts, :provenance, []), :provenance),
         :ok <- validate_map(Keyword.get(opts, :metadata, %{}), :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         type: type,
         params: Keyword.get(opts, :params, %{}),
         inputs: Keyword.get(opts, :inputs, []),
         outputs: Keyword.get(opts, :outputs, ["output"]),
         policy: Keyword.get(opts, :policy, %{}),
         provenance: Keyword.get(opts, :provenance, []),
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  @spec new!(String.t(), type() | String.t(), keyword()) :: t()
  def new!(id, type, opts \\ []) do
    case new(id, type, opts) do
      {:ok, blueprint} -> blueprint
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = blueprint), do: validate(blueprint)
  def from_input(input) when is_list(input), do: input |> Map.new() |> from_input()

  def from_input(input) when is_map(input) do
    new(get(input, :id, nil), get(input, :type, get(input, :kind, nil)),
      params: get(input, :params, %{}),
      inputs: get(input, :inputs, []),
      outputs: get(input, :outputs, ["output"]),
      policy: get(input, :policy, %{}),
      provenance: get(input, :provenance, []),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("expected an assistant component blueprint",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = blueprint) do
    new(blueprint.id, blueprint.type,
      params: blueprint.params,
      inputs: blueprint.inputs,
      outputs: blueprint.outputs,
      policy: blueprint.policy,
      provenance: blueprint.provenance,
      metadata: blueprint.metadata
    )
  end

  @spec types() :: [type()]
  def types, do: ComponentCatalog.types()

  defp normalize_type(type) when is_atom(type) do
    if type in ComponentCatalog.types() do
      {:ok, type}
    else
      invalid_type(type)
    end
  end

  defp normalize_type(type) when is_binary(type) do
    normalized = type |> String.downcase() |> String.replace("-", "_")

    ComponentCatalog.types()
    |> Enum.find(&(Atom.to_string(&1) == normalized))
    |> case do
      nil -> invalid_type(type)
      type -> {:ok, type}
    end
  end

  defp normalize_type(type), do: invalid_type(type)

  defp invalid_type(type) do
    {:error,
     Error.validation("invalid assistant component blueprint type",
       source: __MODULE__,
       details: %{type: type, valid: ComponentCatalog.types()}
     )}
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("component blueprint id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("component blueprint #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("component blueprint #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
