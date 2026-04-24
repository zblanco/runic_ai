defmodule RunicAI.RLM.Plan do
  @moduledoc """
  Validated, inspectable recursive execution plan.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.CostEstimate
  alias RunicAI.RLM.PlanNode
  alias RunicAI.RLM.Policy
  alias RunicAI.RLM.TaskKind

  @enforce_keys [:id, :task_kind, :nodes, :policy, :metadata]
  defstruct [
    :id,
    :task_kind,
    :nodes,
    :root_node_ids,
    :output_node_id,
    :policy,
    :cost_estimate,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          task_kind: TaskKind.t(),
          nodes: [PlanNode.t()],
          root_node_ids: [String.t()] | nil,
          output_node_id: String.t() | nil,
          policy: Policy.t(),
          cost_estimate: CostEstimate.t() | nil,
          metadata: map()
        }

  @spec new(TaskKind.t(), [PlanNode.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(task_kind, nodes, opts \\ []) when is_list(nodes) and is_list(opts) do
    id = Keyword.get(opts, :id) || "rlm-plan:#{System.unique_integer([:positive])}"

    with :ok <- validate_id(id),
         :ok <- validate_task_kind(task_kind),
         {:ok, nodes} <- normalize_nodes(nodes),
         :ok <- validate_unique_node_ids(nodes),
         {:ok, policy} <- Policy.from_input(Keyword.get(opts, :policy)),
         {:ok, cost_estimate} <- CostEstimate.from_input(Keyword.get(opts, :cost_estimate)),
         :ok <-
           validate_node_refs(
             nodes,
             Keyword.get(opts, :root_node_ids),
             Keyword.get(opts, :output_node_id)
           ),
         :ok <- validate_metadata(Keyword.get(opts, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         task_kind: task_kind,
         nodes: nodes,
         root_node_ids: Keyword.get(opts, :root_node_ids),
         output_node_id: Keyword.get(opts, :output_node_id),
         policy: policy,
         cost_estimate: cost_estimate,
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  @spec new!(TaskKind.t(), [PlanNode.t()], keyword()) :: t()
  def new!(task_kind, nodes, opts \\ []) do
    case new(task_kind, nodes, opts) do
      {:ok, plan} -> plan
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = plan) do
    new(plan.task_kind, plan.nodes,
      id: plan.id,
      root_node_ids: plan.root_node_ids,
      output_node_id: plan.output_node_id,
      policy: plan.policy,
      cost_estimate: plan.cost_estimate,
      metadata: plan.metadata
    )
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("plan id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_task_kind(task_kind) do
    if TaskKind.valid?(task_kind) do
      :ok
    else
      {:error,
       Error.validation("invalid RLM task kind: #{inspect(task_kind)}",
         source: __MODULE__,
         details: %{task_kind: task_kind, valid_kinds: TaskKind.valid_kinds()}
       )}
    end
  end

  defp normalize_nodes(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn
      %PlanNode{} = node, {:ok, acc} ->
        case PlanNode.validate(node) do
          {:ok, node} -> {:cont, {:ok, [node | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      other, _acc ->
        {:halt,
         {:error,
          Error.validation("plan nodes must be PlanNode structs",
            source: __MODULE__,
            details: %{node: other}
          )}}
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp validate_unique_node_ids(nodes) do
    ids = Enum.map(nodes, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      duplicates ->
        {:error,
         Error.validation("plan node ids must be unique",
           source: __MODULE__,
           details: %{duplicate_node_ids: duplicates}
         )}
    end
  end

  defp validate_node_refs(nodes, root_node_ids, output_node_id) do
    ids = MapSet.new(Enum.map(nodes, & &1.id))
    refs = List.wrap(root_node_ids) ++ List.wrap(output_node_id)

    case Enum.reject(refs, &MapSet.member?(ids, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.validation("plan references unknown node ids",
           source: __MODULE__,
           details: %{missing_node_ids: missing}
         )}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("plan metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
