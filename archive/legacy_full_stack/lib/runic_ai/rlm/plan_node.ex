defmodule RunicAI.RLM.PlanNode do
  @moduledoc """
  One graph-friendly node in an RLM plan.
  """

  alias RunicAI.Error

  @valid_ops [:split, :filter, :map_leaf, :reduce, :materialize, :review, :child_workflow]

  @enforce_keys [:id, :op]
  defstruct [:id, :op, inputs: [], params: %{}, parent_ids: [], metadata: %{}]

  @type op :: :split | :filter | :map_leaf | :reduce | :materialize | :review | :child_workflow

  @type t :: %__MODULE__{
          id: String.t(),
          op: op(),
          inputs: [term()],
          params: map(),
          parent_ids: [String.t()],
          metadata: map()
        }

  @spec new(String.t() | integer(), op(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, op, opts \\ []) when is_list(opts) do
    id = normalize_id(id)

    node = %__MODULE__{
      id: id,
      op: op,
      inputs: Keyword.get(opts, :inputs, []),
      params: Keyword.get(opts, :params, %{}),
      parent_ids: Keyword.get(opts, :parent_ids, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(node)
  end

  @spec new!(String.t() | integer(), op(), keyword()) :: t()
  def new!(id, op, opts \\ []) do
    case new(id, op, opts) do
      {:ok, node} -> node
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = node) do
    with :ok <- validate_id(node.id),
         :ok <- validate_op(node.op),
         :ok <- validate_list(node.inputs, :inputs),
         :ok <- validate_map(node.params, :params),
         :ok <- validate_parent_ids(node.parent_ids),
         :ok <- validate_map(node.metadata, :metadata) do
      {:ok, node}
    end
  end

  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id), do: to_string(id)

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("plan node id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_op(op) when op in @valid_ops, do: :ok

  defp validate_op(op) do
    {:error,
     Error.validation("invalid plan node op: #{inspect(op)}",
       source: __MODULE__,
       details: %{op: op, valid_ops: @valid_ops}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("plan node #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_parent_ids(parent_ids) when is_list(parent_ids) do
    if Enum.all?(parent_ids, &(is_binary(&1) and &1 != "")) do
      :ok
    else
      {:error,
       Error.validation("plan node parent_ids must contain non-empty strings",
         source: __MODULE__,
         details: %{parent_ids: parent_ids}
       )}
    end
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("plan node #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
