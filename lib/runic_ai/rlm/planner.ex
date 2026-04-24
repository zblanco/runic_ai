defmodule RunicAI.RLM.Planner do
  @moduledoc """
  Deterministic default planner for small, explicit RLM plan shapes.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.CostEstimate
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.Plan
  alias RunicAI.RLM.PlanNode
  alias RunicAI.RLM.Policy
  alias RunicAI.RLM.Probe
  alias RunicAI.RLM.TaskKind

  @spec plan(TaskKind.t(), [EnvironmentRef.t()], keyword()) ::
          {:ok, Plan.t()} | {:error, Error.t()}
  def plan(task_kind, source_refs, opts \\ [])
      when is_list(source_refs) and is_list(opts) do
    with :ok <- validate_task_kind(task_kind),
         {:ok, policy} <- Policy.from_input(Keyword.get(opts, :policy)),
         {:ok, source_refs} <- normalize_source_refs(source_refs),
         probes <- Keyword.get(opts, :probes, []),
         {:ok, cost_estimate} <- estimate(source_refs, probes, policy, opts),
         {:ok, nodes} <- build_nodes(source_refs, policy, task_kind, opts) do
      Plan.new(task_kind, nodes,
        id: Keyword.get(opts, :id),
        root_node_ids: ["split"],
        output_node_id: "reduce",
        policy: policy,
        cost_estimate: cost_estimate,
        metadata: Keyword.get(opts, :metadata, %{})
      )
    end
  end

  @spec estimate([EnvironmentRef.t()], [Probe.t()], Policy.t(), keyword()) ::
          {:ok, CostEstimate.t()} | {:error, Error.t()}
  def estimate(source_refs, probes, %Policy{} = policy, _opts \\ []) do
    total_size =
      probes
      |> Enum.filter(&match?(%Probe{}, &1))
      |> Enum.map(& &1.size)
      |> Enum.sum()

    source_count = max(length(source_refs), 1)

    leaf_calls =
      if total_size > 0 do
        ceil_div(total_size, policy.leaf_window)
      else
        source_count
      end

    reducer_calls = if leaf_calls > 1, do: 1, else: 0

    CostEstimate.new(
      leaf_calls: leaf_calls,
      reducer_calls: reducer_calls,
      environment_reads: leaf_calls,
      input_tokens: leaf_calls * policy.leaf_window,
      latency_class: latency_class(leaf_calls),
      assumptions: [
        "default planner uses one split, one leaf map, and one final reduce",
        "leaf_window is used as a rough input token proxy until tokenizer support is added"
      ],
      metadata: %{source_count: source_count, total_source_size: total_size}
    )
  end

  defp build_nodes(source_refs, %Policy{} = policy, task_kind, opts) do
    chunk_size = Keyword.get(opts, :chunk_size, policy.leaf_window)

    nodes = [
      PlanNode.new!("split", :split,
        inputs: source_refs,
        params: %{chunk_size: chunk_size}
      ),
      PlanNode.new!("map_leaves", :map_leaf,
        parent_ids: ["split"],
        params: %{task_kind: task_kind}
      ),
      PlanNode.new!("reduce", :reduce,
        parent_ids: ["map_leaves"],
        params: %{mode: :concat}
      )
    ]

    {:ok, nodes}
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

  defp normalize_source_refs(source_refs) do
    Enum.reduce_while(source_refs, {:ok, []}, fn
      %EnvironmentRef{} = ref, {:ok, acc} ->
        case EnvironmentRef.validate(ref) do
          {:ok, ref} -> {:cont, {:ok, [ref | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      other, _acc ->
        {:halt,
         {:error,
          Error.validation("planner source refs must be EnvironmentRef structs",
            source: __MODULE__,
            details: %{source_ref: other}
          )}}
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  defp ceil_div(left, right), do: div(left + right - 1, right)

  defp latency_class(leaf_calls) when leaf_calls <= 1, do: :single
  defp latency_class(leaf_calls) when leaf_calls <= 8, do: :small_parallel
  defp latency_class(_leaf_calls), do: :large_parallel
end
