defmodule RunicAI.RLM.LambdaPlan do
  @moduledoc """
  Typed plan envelope for Lambda-style long-context decomposition.

  A Lambda plan records the objective, input shape, operator sequence, budgets,
  estimates, and context-slice contracts before execution. The model may help
  classify the task or author leaf prompts later, but this struct keeps
  recursive control flow as validated data that can be traced and replayed.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.ContextSliceContract
  alias RunicAI.RLM.CostEstimate
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.Plan
  alias RunicAI.RLM.Policy
  alias RunicAI.RLM.TaskKind

  @operators [:split, :map, :filter, :reduce, :cross, :review, :generate]
  @fallback_strategies [
    :direct_standard_agent,
    :subagent_delegation,
    :generated_sandbox_component,
    :sandbox_repl,
    :host_edit_workflow
  ]

  @enforce_keys [
    :id,
    :objective,
    :task_kind,
    :source_refs,
    :operators,
    :context_contracts,
    :policy,
    :cost_estimate,
    :detection,
    :budgets,
    :estimates,
    :metadata
  ]
  defstruct [
    :id,
    :objective,
    :task_kind,
    :source_refs,
    :operators,
    :context_contracts,
    :policy,
    :cost_estimate,
    :detection,
    :budgets,
    :estimates,
    :fallback_strategy,
    :plan,
    metadata: %{}
  ]

  @type operator :: :split | :map | :filter | :reduce | :cross | :review | :generate

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          task_kind: TaskKind.t(),
          source_refs: [EnvironmentRef.t()],
          operators: [map()],
          context_contracts: [ContextSliceContract.t()],
          policy: Policy.t(),
          cost_estimate: CostEstimate.t(),
          detection: map(),
          budgets: map(),
          estimates: map(),
          fallback_strategy: atom() | nil,
          plan: Plan.t() | nil,
          metadata: map()
        }

  @spec operators() :: [operator()]
  def operators, do: @operators

  @spec new(String.t(), TaskKind.t(), [EnvironmentRef.t()], keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(objective, task_kind, source_refs, opts \\ [])
      when is_binary(objective) and is_list(source_refs) and is_list(opts) do
    id = Keyword.get(opts, :id) || "lambda-plan:#{System.unique_integer([:positive])}"

    with :ok <- validate_id(id),
         :ok <- validate_objective(objective),
         :ok <- validate_task_kind(task_kind),
         {:ok, source_refs} <- normalize_source_refs(source_refs),
         {:ok, policy} <- Policy.from_input(Keyword.get(opts, :policy)),
         {:ok, cost_estimate} <- CostEstimate.from_input(Keyword.get(opts, :cost_estimate)),
         {:ok, operators} <- normalize_operators(Keyword.get(opts, :operators), task_kind),
         {:ok, contracts} <-
           normalize_context_contracts(
             Keyword.get(opts, :context_contracts),
             source_refs,
             policy,
             task_kind
           ),
         :ok <- validate_detection(Keyword.get(opts, :detection, %{})),
         :ok <- validate_map(Keyword.get(opts, :budgets, %{}), :budgets),
         :ok <- validate_map(Keyword.get(opts, :estimates, %{}), :estimates),
         {:ok, fallback_strategy} <-
           normalize_fallback_strategy(Keyword.get(opts, :fallback_strategy)),
         :ok <- validate_optional_plan(Keyword.get(opts, :plan)),
         :ok <- validate_metadata(Keyword.get(opts, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         objective: objective,
         task_kind: task_kind,
         source_refs: source_refs,
         operators: operators,
         context_contracts: contracts,
         policy: policy,
         cost_estimate: cost_estimate,
         detection: Keyword.get(opts, :detection, %{}),
         budgets: Keyword.get(opts, :budgets, %{}),
         estimates: Keyword.get(opts, :estimates, %{}),
         fallback_strategy: fallback_strategy,
         plan: Keyword.get(opts, :plan),
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  @spec new!(String.t(), TaskKind.t(), [EnvironmentRef.t()], keyword()) :: t()
  def new!(objective, task_kind, source_refs, opts \\ []) do
    case new(objective, task_kind, source_refs, opts) do
      {:ok, plan} -> plan
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_plan(String.t(), Plan.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_plan(objective, %Plan{} = plan, opts \\ []) when is_list(opts) do
    with {:ok, plan} <- Plan.validate(plan),
         {:ok, source_refs} <- source_refs_from_plan(plan) do
      new(objective, plan.task_kind, source_refs,
        id: Keyword.get(opts, :id) || "lambda:#{plan.id}",
        operators: Keyword.get(opts, :operators),
        context_contracts: Keyword.get(opts, :context_contracts),
        policy: plan.policy,
        cost_estimate: plan.cost_estimate,
        detection: Keyword.get(opts, :detection, default_detection(plan)),
        budgets: Keyword.get(opts, :budgets, budgets_from_policy(plan.policy)),
        estimates:
          Keyword.get(opts, :estimates, estimates_from_cost(plan.cost_estimate, plan.policy)),
        fallback_strategy: Keyword.get(opts, :fallback_strategy, :sandbox_repl),
        plan: plan,
        metadata: Keyword.get(opts, :metadata, %{rlm_plan_id: plan.id})
      )
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = lambda_plan) do
    new(lambda_plan.objective, lambda_plan.task_kind, lambda_plan.source_refs,
      id: lambda_plan.id,
      operators: lambda_plan.operators,
      context_contracts: lambda_plan.context_contracts,
      policy: lambda_plan.policy,
      cost_estimate: lambda_plan.cost_estimate,
      detection: lambda_plan.detection,
      budgets: lambda_plan.budgets,
      estimates: lambda_plan.estimates,
      fallback_strategy: lambda_plan.fallback_strategy,
      plan: lambda_plan.plan,
      metadata: lambda_plan.metadata
    )
  end

  @spec operator_names(t()) :: [operator()]
  def operator_names(%__MODULE__{} = lambda_plan) do
    Enum.map(lambda_plan.operators, &Map.fetch!(&1, :op))
  end

  @spec call_accounting(t(), map()) :: map()
  def call_accounting(%__MODULE__{} = lambda_plan, actual_metrics) when is_map(actual_metrics) do
    planned = planned_calls(lambda_plan)
    actual = actual_calls(actual_metrics)

    %{
      planned: planned,
      actual: actual,
      deltas: %{
        leaf_calls: actual.leaf_calls - planned.leaf_calls,
        reduce_calls: actual.reduce_calls - planned.reduce_calls,
        review_calls: actual.review_calls - planned.review_calls,
        sandbox_executions: actual.sandbox_executions - planned.sandbox_executions
      },
      matched?: planned == actual
    }
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("Lambda plan id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_objective(objective) when is_binary(objective) and objective != "", do: :ok

  defp validate_objective(objective) do
    {:error,
     Error.validation("Lambda plan objective must be a non-empty string",
       source: __MODULE__,
       details: %{objective: objective}
     )}
  end

  defp validate_task_kind(task_kind) do
    if TaskKind.valid?(task_kind) do
      :ok
    else
      {:error,
       Error.validation("invalid Lambda plan task kind: #{inspect(task_kind)}",
         source: __MODULE__,
         details: %{task_kind: task_kind, valid_kinds: TaskKind.valid_kinds()}
       )}
    end
  end

  defp normalize_source_refs([]) do
    {:error,
     Error.validation("Lambda plan requires at least one source ref",
       source: __MODULE__,
       details: %{source_refs: []}
     )}
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
          Error.validation("Lambda plan source refs must be EnvironmentRef structs",
            source: __MODULE__,
            details: %{source_ref: other}
          )}}
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  defp normalize_operators(nil, task_kind), do: {:ok, default_operators(task_kind)}

  defp normalize_operators(operators, _task_kind) when is_list(operators) do
    operators
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {operator, index}, {:ok, acc} ->
      case normalize_operator(operator, index) do
        {:ok, operator} -> {:cont, {:ok, [operator | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, []} -> invalid_operators(operators)
      {:ok, operators} -> {:ok, Enum.reverse(operators)}
      error -> error
    end
  end

  defp normalize_operators(operators, _task_kind), do: invalid_operators(operators)

  defp normalize_operator(op, index) when is_atom(op), do: normalize_operator(%{op: op}, index)

  defp normalize_operator(operator, index) when is_map(operator) do
    op = operator |> Map.get(:op) || Map.get(operator, "op")

    case normalize_operator_name(op) do
      {:ok, op} ->
        {:ok,
         operator
         |> atom_key(:op, op)
         |> atom_key(
           :id,
           Map.get(operator, :id) || Map.get(operator, "id") || default_operator_id(op, index)
         )}

      {:error, _error} ->
        invalid_operator(op, operator)
    end
  end

  defp normalize_operator(operator, _index) do
    {:error,
     Error.validation("Lambda operators must be atoms or maps",
       source: __MODULE__,
       details: %{operator: operator}
     )}
  end

  defp normalize_operator_name(op) when op in @operators, do: {:ok, op}

  defp normalize_operator_name(op) when is_binary(op) do
    Enum.find(@operators, &(Atom.to_string(&1) == op))
    |> case do
      nil -> {:error, :invalid_operator}
      op -> {:ok, op}
    end
  end

  defp normalize_operator_name(_op), do: {:error, :invalid_operator}

  defp invalid_operator(op, operator) do
    {:error,
     Error.validation("invalid Lambda operator: #{inspect(op)}",
       source: __MODULE__,
       details: %{operator: operator, valid_operators: @operators}
     )}
  end

  defp invalid_operators(operators) do
    {:error,
     Error.validation("Lambda plan operators must be a non-empty list",
       source: __MODULE__,
       details: %{operators: operators}
     )}
  end

  defp normalize_context_contracts(nil, source_refs, policy, task_kind) do
    source_refs
    |> Enum.map(&default_contract(&1, policy, task_kind))
    |> normalize_context_contracts(source_refs, policy, task_kind)
  end

  defp normalize_context_contracts(contracts, _source_refs, _policy, _task_kind)
       when is_list(contracts) do
    contracts
    |> Enum.reduce_while({:ok, []}, fn contract, {:ok, acc} ->
      case ContextSliceContract.from_input(contract) do
        {:ok, contract} -> {:cont, {:ok, [contract | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, []} ->
        {:error,
         Error.validation("Lambda plan requires at least one context slice contract",
           source: __MODULE__
         )}

      {:ok, contracts} ->
        {:ok, Enum.reverse(contracts)}

      error ->
        error
    end
  end

  defp normalize_context_contracts(contracts, _source_refs, _policy, _task_kind) do
    {:error,
     Error.validation("Lambda plan context contracts must be a list",
       source: __MODULE__,
       details: %{context_contracts: contracts}
     )}
  end

  defp default_contract(%EnvironmentRef{} = source_ref, %Policy{} = policy, task_kind) do
    ContextSliceContract.new!(
      source_ref,
      token_budget: policy.leaf_window,
      expected_output_schema: expected_output_schema(task_kind),
      merge_policy: merge_policy(task_kind),
      review_policy: %{checks: [:coverage, :specificity, :provenance]},
      metadata: %{generated_by: __MODULE__}
    )
  end

  defp validate_detection(detection) when is_map(detection), do: :ok

  defp validate_detection(detection) do
    {:error,
     Error.validation("Lambda plan detection must be a map",
       source: __MODULE__,
       details: %{detection: detection}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("Lambda plan #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_fallback_strategy(nil), do: {:ok, nil}

  defp normalize_fallback_strategy(strategy) when strategy in @fallback_strategies,
    do: {:ok, strategy}

  defp normalize_fallback_strategy(strategy) when is_binary(strategy) do
    Enum.find(@fallback_strategies, &(Atom.to_string(&1) == strategy))
    |> case do
      nil -> invalid_fallback_strategy(strategy)
      strategy -> {:ok, strategy}
    end
  end

  defp normalize_fallback_strategy(strategy), do: invalid_fallback_strategy(strategy)

  defp invalid_fallback_strategy(strategy) do
    {:error,
     Error.validation("invalid Lambda fallback strategy: #{inspect(strategy)}",
       source: __MODULE__,
       details: %{fallback_strategy: strategy, valid_strategies: @fallback_strategies}
     )}
  end

  defp validate_optional_plan(nil), do: :ok

  defp validate_optional_plan(%Plan{} = plan) do
    case Plan.validate(plan) do
      {:ok, _plan} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp validate_optional_plan(plan) do
    {:error,
     Error.validation("Lambda plan embedded plan must be an RLM Plan or nil",
       source: __MODULE__,
       details: %{plan: plan}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("Lambda plan metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp source_refs_from_plan(%Plan{} = plan) do
    plan.nodes
    |> Enum.find(&(&1.op == :split))
    |> case do
      nil -> {:ok, []}
      split_node -> normalize_source_refs(split_node.inputs)
    end
  end

  defp default_detection(%Plan{} = plan) do
    %{
      task_type: plan.task_kind,
      source_kind: :environment_ref,
      decomposition_reason: :deterministic_split_map_reduce,
      model_classifier_result: nil,
      deterministic_fallback_reason: :default_planner
    }
  end

  defp budgets_from_policy(%Policy{} = policy) do
    %{
      max_leaf_calls: policy.max_leaf_calls,
      max_depth: policy.max_depth,
      max_concurrency: policy.concurrency,
      leaf_window: policy.leaf_window
    }
    |> reject_nil_values()
  end

  defp estimates_from_cost(%CostEstimate{} = estimate, %Policy{} = policy) do
    %{
      leaf_calls: estimate.leaf_calls,
      review_calls: review_calls(policy),
      reduce_calls: estimate.reducer_calls,
      max_depth: policy.max_depth,
      max_concurrency: policy.concurrency,
      expected_sandbox_executions: Map.get(estimate.metadata, :expected_sandbox_executions, 0),
      escalation_fallback: :sandbox_repl
    }
    |> reject_nil_values()
  end

  defp default_operators(task_kind) when task_kind in [:qa, :extraction] do
    [
      %{id: "split", op: :split, by: :bounded_context},
      %{id: "filter", op: :filter, predicate: :relevant_to_objective},
      %{id: "map", op: :map, component: :llm_map, schema: expected_output_schema(task_kind)},
      %{id: "reduce", op: :reduce, reducer: merge_policy(task_kind)},
      %{id: "review", op: :review, checks: [:coverage, :specificity, :provenance]},
      %{id: "generate", op: :generate, component: :report_composer}
    ]
  end

  defp default_operators(task_kind) do
    [
      %{id: "split", op: :split, by: :bounded_context},
      %{id: "map", op: :map, component: :llm_map, schema: expected_output_schema(task_kind)},
      %{id: "reduce", op: :reduce, reducer: merge_policy(task_kind)},
      %{id: "review", op: :review, checks: [:coverage, :specificity, :provenance]},
      %{id: "generate", op: :generate, component: :report_composer}
    ]
  end

  defp expected_output_schema(:classification), do: :label_record
  defp expected_output_schema(:extraction), do: :extracted_record
  defp expected_output_schema(:qa), do: :answer_with_evidence
  defp expected_output_schema(:codebase_qa), do: :answer_with_code_refs
  defp expected_output_schema(:report_generation), do: :section_records
  defp expected_output_schema(_task_kind), do: :summary_record

  defp merge_policy(:classification), do: :majority_vote
  defp merge_policy(:extraction), do: :merge_records
  defp merge_policy(:qa), do: :select_relevant
  defp merge_policy(:codebase_qa), do: :select_relevant
  defp merge_policy(:analysis), do: :combine_analysis
  defp merge_policy(_task_kind), do: :merge_summaries

  defp review_calls(%Policy{review_policy: false}), do: 0
  defp review_calls(%Policy{}), do: 1

  defp planned_calls(%__MODULE__{} = lambda_plan) do
    %{
      leaf_calls:
        count_field(lambda_plan.estimates, :leaf_calls, lambda_plan.cost_estimate.leaf_calls),
      reduce_calls:
        count_field(lambda_plan.estimates, :reduce_calls, lambda_plan.cost_estimate.reducer_calls),
      review_calls:
        count_field(lambda_plan.estimates, :review_calls, review_calls(lambda_plan.policy)),
      sandbox_executions: count_field(lambda_plan.estimates, :expected_sandbox_executions, 0)
    }
  end

  defp actual_calls(metrics) do
    %{
      leaf_calls:
        count_field(metrics, :lambda_map_calls) ||
          count_field(metrics, :llm_map_calls) ||
          count_field(metrics, :leaf_calls, 0),
      reduce_calls:
        count_field(metrics, :lambda_reduce_calls) ||
          count_field(metrics, :reduce_calls) ||
          count_field(metrics, :reducer_calls, 0),
      review_calls:
        count_field(metrics, :lambda_review_calls) ||
          count_field(metrics, :review_calls, 0),
      sandbox_executions:
        count_field(metrics, :sandbox_executions) ||
          count_field(metrics, :expected_sandbox_executions, 0)
    }
  end

  defp count_field(map, key, default \\ nil) when is_map(map) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), default)) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end

  defp atom_key(map, key, value), do: Map.put(Map.delete(map, Atom.to_string(key)), key, value)

  defp default_operator_id(op, index), do: "#{op}:#{index}"

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
