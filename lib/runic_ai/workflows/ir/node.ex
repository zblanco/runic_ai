defmodule RunicAI.Workflows.IR.Node do
  @moduledoc """
  One catalog-backed semantic node in workflow IR V1.
  """

  alias RunicAI.Error
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.JSONValue

  @enforce_keys [:id, :component, :contract]
  @derive Jason.Encoder
  defstruct [
    :id,
    :component,
    :contract,
    kind: :component,
    arguments: %{},
    policy: %{},
    effects: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          component: String.t(),
          contract: Catalog.contract(),
          arguments: map(),
          policy: map(),
          effects: [atom()],
          metadata: map()
        }

  @spec new(String.t(), atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, component, opts \\ []) when is_list(opts) do
    with :ok <- validate_id(id),
         {:ok, resolved_contract} <- Catalog.resolve(component),
         {:ok, contract} <- normalize_contract(Keyword.get(opts, :contract), resolved_contract),
         :ok <- validate_map(Keyword.get(opts, :arguments, %{}), :arguments),
         :ok <- validate_map(Keyword.get(opts, :policy, %{}), :policy),
         :ok <- validate_map(Keyword.get(opts, :metadata, %{}), :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         component: contract_value(contract, :key),
         contract: contract,
         kind: Keyword.get(opts, :kind, :component),
         arguments: Keyword.get(opts, :arguments, %{}),
         policy: Keyword.get(opts, :policy, %{}),
         effects: contract_value(contract, :effects, []),
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  @spec from_input(t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = node), do: validate(node)

  def from_input(input) when is_map(input) do
    id = get(input, :id)
    component = get(input, :component)

    new(id, component,
      kind: normalize_kind(get(input, :kind, :component)),
      contract: get(input, :contract),
      arguments: get(input, :arguments, %{}),
      policy: get(input, :policy, %{}),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("workflow IR node must be a map",
       source: __MODULE__,
       details: %{code: :invalid_ir_node, input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = node) do
    new(node.id, node.component,
      kind: node.kind,
      contract: node.contract,
      arguments: node.arguments,
      policy: node.policy,
      metadata: node.metadata
    )
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("workflow IR node id must be a non-empty string",
       source: __MODULE__,
       details: %{code: :invalid_node_id, id: id}
     )}
  end

  defp validate_map(value, field) when is_map(value),
    do: JSONValue.validate_unambiguous(value, __MODULE__, field)

  defp validate_map(value, field) do
    {:error,
     Error.validation("workflow IR node #{field} must be a map",
       source: __MODULE__,
       details: %{code: :invalid_node_field, field: field, value: value}
     )}
  end

  defp normalize_contract(nil, resolved), do: {:ok, resolved}
  defp normalize_contract(contract, _resolved) when is_map(contract), do: {:ok, contract}

  defp normalize_contract(contract, _resolved) do
    {:error,
     Error.validation("workflow IR node contract must be a map",
       source: __MODULE__,
       details: %{code: :invalid_node_contract, contract: contract}
     )}
  end

  defp contract_value(contract, key, default \\ nil),
    do: Map.get(contract, key, Map.get(contract, Atom.to_string(key), default))

  defp normalize_kind("component"), do: :component
  defp normalize_kind("coding"), do: :coding
  defp normalize_kind(kind), do: kind

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
