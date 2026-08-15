defmodule RunicAI.Coding.RLM.WorkflowProposal do
  @moduledoc """
  Inert workflow proposal produced by an RLM coding coordinator.

  A proposal describes the desired graph, policies, source refs, expected
  artifacts, and stop conditions. It is not executable until
  `RunicAI.Coding.RLM.WorkflowValidator` accepts it.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.CostEstimate
  alias RunicAI.RLM.Plan
  alias RunicAI.RLM.PlanNode
  alias RunicAI.RLM.Policy
  alias RunicAI.RLM.TaskKind
  alias RunicAI.Coding.RLM.ProposalNode

  @enforce_keys [
    :id,
    :objective,
    :assumptions,
    :sources,
    :nodes,
    :edges,
    :policies,
    :expected_artifacts,
    :stop_conditions,
    :metadata
  ]
  defstruct [
    :id,
    :objective,
    assumptions: [],
    sources: [],
    nodes: [],
    edges: [],
    policies: %{},
    expected_artifacts: [],
    stop_conditions: [],
    metadata: %{}
  ]

  @type edge :: %{required(:from) => String.t(), required(:to) => String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          assumptions: [String.t()],
          sources: [term()],
          nodes: [ProposalNode.t()],
          edges: [edge()],
          policies: map(),
          expected_artifacts: [term()],
          stop_conditions: [term()],
          metadata: map()
        }

  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(objective, nodes, opts \\ [])

  def new(objective, nodes, opts)
      when is_binary(objective) and is_list(nodes) and is_list(opts) do
    proposal = %__MODULE__{
      id: Keyword.get(opts, :id) || "rlm-coding-proposal:#{System.unique_integer([:positive])}",
      objective: objective,
      assumptions: Keyword.get(opts, :assumptions, []),
      sources: Keyword.get(opts, :sources, []),
      nodes: nodes,
      edges: Keyword.get(opts, :edges, []),
      policies: Keyword.get(opts, :policies, %{}),
      expected_artifacts: Keyword.get(opts, :expected_artifacts, []),
      stop_conditions: Keyword.get(opts, :stop_conditions, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(proposal)
  end

  def new(objective, nodes, opts) do
    cond do
      not is_binary(objective) or objective == "" ->
        validate_objective(objective)

      not is_list(nodes) ->
        {:error,
         Error.validation("workflow proposal nodes must be a list",
           source: __MODULE__,
           details: %{nodes: nodes}
         )}

      not is_list(opts) ->
        {:error,
         Error.validation("workflow proposal opts must be a keyword list",
           source: __MODULE__,
           details: %{opts: opts}
         )}
    end
  end

  @spec new!(String.t(), [ProposalNode.t() | map()], keyword()) :: t()
  def new!(objective, nodes, opts \\ []) do
    case new(objective, nodes, opts) do
      {:ok, proposal} -> proposal
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = proposal), do: validate(proposal)

  def from_input(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, decoded} ->
        from_input(decoded)

      {:error, _error} ->
        {:error,
         Error.validation("workflow proposal must be a map or WorkflowProposal",
           source: __MODULE__,
           details: %{input: input}
         )}
    end
  end

  def from_input(input) when is_list(input) do
    input |> Map.new() |> from_input()
  end

  def from_input(input) when is_map(input) do
    new(get(input, :objective), normalize_list(get(input, :nodes, [])),
      id: get(input, :id),
      assumptions: normalize_list(get(input, :assumptions, [])),
      sources: normalize_list(get(input, :sources, [])),
      edges: normalize_list(get(input, :edges, [])),
      policies: normalize_map(get(input, :policies, %{})),
      expected_artifacts: normalize_list(get(input, :expected_artifacts, [])),
      stop_conditions: normalize_list(get(input, :stop_conditions, [])),
      metadata: normalize_map(get(input, :metadata, %{}))
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("workflow proposal must be a map or WorkflowProposal",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = proposal) do
    with :ok <- validate_id(proposal.id),
         :ok <- validate_objective(proposal.objective),
         :ok <- validate_list(proposal.assumptions, :assumptions),
         :ok <- validate_list(proposal.sources, :sources),
         :ok <- validate_list(proposal.nodes, :nodes),
         {:ok, nodes} <- normalize_nodes(proposal.nodes),
         :ok <- validate_list(proposal.edges, :edges),
         {:ok, edges} <- normalize_edges(proposal.edges),
         :ok <- validate_map(proposal.policies, :policies),
         :ok <- validate_list(proposal.expected_artifacts, :expected_artifacts),
         :ok <- validate_list(proposal.stop_conditions, :stop_conditions),
         :ok <- validate_map(proposal.metadata, :metadata) do
      {:ok, %{proposal | nodes: nodes, edges: edges}}
    end
  end

  @spec to_plan(t(), keyword()) :: {:ok, Plan.t()} | {:error, Error.t()}
  def to_plan(%__MODULE__{} = proposal, opts \\ []) when is_list(opts) do
    task_kind = Keyword.get(opts, :task_kind, :analysis)

    with {:ok, proposal} <- validate(proposal),
         :ok <- validate_task_kind(task_kind),
         {:ok, policy} <- Policy.from_input(Map.get(proposal.policies, :rlm) || %{}),
         {:ok, cost_estimate} <-
           CostEstimate.from_input(Map.get(proposal.policies, :cost_estimate)),
         nodes = Enum.map(proposal.nodes, &to_plan_node(&1, proposal.edges)) do
      Plan.new(task_kind, nodes,
        id: proposal.id,
        root_node_ids: root_node_ids(proposal),
        output_node_id: output_node_id(proposal),
        policy: policy,
        cost_estimate: cost_estimate,
        metadata: Map.merge(proposal.metadata, %{workflow_proposal?: true})
      )
    end
  end

  defp to_plan_node(%ProposalNode{} = node, edges) do
    PlanNode.new!(node.id, plan_op(node.kind),
      inputs: node.inputs,
      parent_ids: parent_ids(node.id, edges),
      params: node.params,
      metadata: Map.merge(node.metadata, %{proposal_kind: node.kind})
    )
  end

  defp plan_op(:llm_leaf), do: :map_leaf
  defp plan_op(:tool), do: :map_leaf
  defp plan_op(:command), do: :map_leaf
  defp plan_op(:script), do: :map_leaf
  defp plan_op(:deterministic_step), do: :map_leaf
  defp plan_op(:agent), do: :child_workflow
  defp plan_op(:edit), do: :map_leaf
  defp plan_op(:verification_gate), do: :map_leaf
  defp plan_op(:reducer), do: :reduce
  defp plan_op(:review_gate), do: :review
  defp plan_op(:workflow_patch), do: :review

  defp parent_ids(node_id, edges) do
    edges
    |> Enum.filter(&(&1.to == node_id))
    |> Enum.map(& &1.from)
    |> Enum.uniq()
  end

  defp root_node_ids(%__MODULE__{} = proposal) do
    proposal.nodes
    |> Enum.reject(fn node -> Enum.any?(proposal.edges, &(&1.to == node.id)) end)
    |> Enum.map(& &1.id)
  end

  defp output_node_id(%__MODULE__{nodes: []}), do: nil
  defp output_node_id(%__MODULE__{nodes: nodes}), do: List.last(nodes).id

  defp validate_task_kind(task_kind) do
    if TaskKind.valid?(task_kind) do
      :ok
    else
      {:error,
       Error.validation("invalid RLM task kind for workflow proposal plan mapping",
         source: __MODULE__,
         details: %{task_kind: task_kind}
       )}
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("workflow proposal id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_objective(objective) when is_binary(objective) and objective != "", do: :ok

  defp validate_objective(objective) do
    {:error,
     Error.validation("workflow proposal objective must be a non-empty string",
       source: __MODULE__,
       details: %{objective: objective}
     )}
  end

  defp normalize_nodes(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case ProposalNode.from_input(node) do
        {:ok, node} -> {:cont, {:ok, [node | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp normalize_edges(edges) do
    edges
    |> Enum.reduce_while({:ok, []}, fn edge, {:ok, acc} ->
      edge = normalize_map(edge)
      from = get(edge, :from)
      to = get(edge, :to)

      if is_binary(from) and from != "" and is_binary(to) and to != "" do
        {:cont, {:ok, [%{from: from, to: to} | acc]}}
      else
        {:halt,
         {:error,
          Error.validation("workflow proposal edges require non-empty from/to ids",
            source: __MODULE__,
            details: %{edge: edge}
          )}}
      end
    end)
    |> case do
      {:ok, edges} -> {:ok, Enum.reverse(edges)}
      error -> error
    end
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("workflow proposal #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("workflow proposal #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(value) when is_binary(value), do: decode_map(value)
  defp normalize_map(_value), do: %{}

  defp normalize_list(nil), do: []
  defp normalize_list(value) when is_list(value), do: value

  defp normalize_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> decoded
      {:ok, decoded} -> [decoded]
      {:error, _error} -> [value]
    end
  end

  defp normalize_list(value), do: List.wrap(value)

  defp decode_map(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} when is_list(decoded) -> Map.new(decoded)
      _other -> %{}
    end
  end

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
