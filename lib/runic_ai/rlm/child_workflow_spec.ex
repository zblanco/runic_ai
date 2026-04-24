defmodule RunicAI.RLM.ChildWorkflowSpec do
  @moduledoc """
  Description of child workflow work spawned by an RLM plan.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.Policy

  @enforce_keys [:id, :workflow, :input, :policy, :metadata]
  defstruct [:id, :parent_node_id, :workflow, input: %{}, policy: nil, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_node_id: String.t() | nil,
          workflow: term(),
          input: term(),
          policy: Policy.t(),
          metadata: map()
        }

  @spec new(term(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(workflow, input, opts \\ []) when is_list(opts) do
    spec = %__MODULE__{
      id: Keyword.get(opts, :id) || "child-workflow:#{System.unique_integer([:positive])}",
      parent_node_id: Keyword.get(opts, :parent_node_id),
      workflow: workflow,
      input: input,
      policy: Keyword.get(opts, :policy),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(spec)
  end

  @spec new!(term(), term(), keyword()) :: t()
  def new!(workflow, input, opts \\ []) do
    case new(workflow, input, opts) do
      {:ok, spec} -> spec
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    with :ok <- validate_id(spec.id),
         :ok <- validate_optional_id(spec.parent_node_id),
         {:ok, policy} <- Policy.from_input(spec.policy),
         :ok <- validate_metadata(spec.metadata) do
      {:ok, %{spec | policy: policy}}
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("child workflow id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_optional_id(nil), do: :ok
  defp validate_optional_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_optional_id(id) do
    {:error,
     Error.validation("child workflow parent_node_id must be a non-empty string or nil",
       source: __MODULE__,
       details: %{parent_node_id: id}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("child workflow metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
