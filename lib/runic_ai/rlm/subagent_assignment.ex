defmodule RunicAI.RLM.SubagentAssignment do
  @moduledoc """
  Validated assignment contract for RLM-style subagent delegation.

  The assignment is deliberately data-only. It describes what a child agent or
  nested strategy may do, what context slice it receives, what tools/profile it
  may see, what budget remains, and how its output should be reviewed.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.ContextSliceContract
  alias RunicAI.RLM.StrategyRouter

  @agent_kinds [:standard, :assistant, :rlm, :workflow]

  @enforce_keys [
    :id,
    :role,
    :objective,
    :strategy,
    :agent_kind,
    :visible_tools,
    :budgets,
    :output_schema,
    :parent,
    :metadata
  ]
  defstruct [
    :id,
    :role,
    :objective,
    :prompt,
    :strategy,
    :agent_kind,
    :context_slice,
    :capability_profile,
    :review_policy,
    visible_tools: [],
    budgets: %{},
    output_schema: %{},
    parent: nil,
    metadata: %{}
  ]

  @type parent_metadata :: %{
          optional(:run_id) => String.t(),
          optional(:strategy) => StrategyRouter.strategy(),
          optional(:depth) => non_neg_integer(),
          optional(:fallback) => StrategyRouter.strategy(),
          optional(:remaining_budgets) => map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          role: String.t(),
          objective: String.t(),
          prompt: String.t() | nil,
          strategy: StrategyRouter.strategy(),
          agent_kind: atom(),
          context_slice: ContextSliceContract.t() | map() | nil,
          capability_profile: atom() | String.t() | nil,
          visible_tools: [String.t()],
          budgets: map(),
          output_schema: map(),
          review_policy: map() | nil,
          parent: parent_metadata() | nil,
          metadata: map()
        }

  @spec agent_kinds() :: [atom()]
  def agent_kinds, do: @agent_kinds

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(input) when is_list(input) or is_map(input) do
    input = input_map(input)
    id = get(input, :id) || "subagent_assignment:#{System.unique_integer([:positive])}"
    role = get(input, :role)
    objective = get(input, :objective)
    prompt = get(input, :prompt)
    strategy = get(input, :strategy, :direct_standard_agent)
    agent_kind = get(input, :agent_kind)
    context_slice = get(input, :context_slice)
    capability_profile = get(input, :capability_profile)
    visible_tools = get(input, :visible_tools, [])
    budgets = get(input, :budgets, %{})
    output_schema = get(input, :output_schema, %{})
    review_policy = get(input, :review_policy)
    parent = get(input, :parent)
    metadata = get(input, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_non_empty_string(role, :role),
         :ok <- validate_non_empty_string(objective, :objective),
         :ok <- validate_optional_string(prompt, :prompt),
         {:ok, strategy} <- normalize_strategy(strategy),
         {:ok, agent_kind} <- normalize_agent_kind(agent_kind || default_agent_kind(strategy)),
         {:ok, context_slice} <- normalize_context_slice(context_slice),
         :ok <- validate_capability_profile(capability_profile),
         {:ok, visible_tools} <- normalize_visible_tools(visible_tools),
         :ok <- validate_budgets(budgets),
         :ok <- validate_output_schema(output_schema),
         :ok <- validate_optional_map(review_policy, :review_policy),
         {:ok, parent} <- normalize_parent(parent),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         role: role,
         objective: objective,
         prompt: prompt,
         strategy: strategy,
         agent_kind: agent_kind,
         context_slice: context_slice,
         capability_profile: capability_profile,
         visible_tools: visible_tools,
         budgets: budgets,
         output_schema: output_schema,
         review_policy: review_policy,
         parent: parent,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, assignment} -> assignment
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = assignment) do
    new(%{
      id: assignment.id,
      role: assignment.role,
      objective: assignment.objective,
      prompt: assignment.prompt,
      strategy: assignment.strategy,
      agent_kind: assignment.agent_kind,
      context_slice: assignment.context_slice,
      capability_profile: assignment.capability_profile,
      visible_tools: assignment.visible_tools,
      budgets: assignment.budgets,
      output_schema: assignment.output_schema,
      review_policy: assignment.review_policy,
      parent: assignment.parent,
      metadata: assignment.metadata
    })
  end

  defp input_map(input) when is_map(input), do: input
  defp input_map(input) when is_list(input), do: Map.new(input)

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp default_agent_kind(:lambda_workflow), do: :workflow
  defp default_agent_kind(:generated_sandbox_component), do: :workflow
  defp default_agent_kind(:sandbox_repl), do: :workflow
  defp default_agent_kind(_strategy), do: :standard

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("subagent assignment id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_non_empty_string(value, field) do
    {:error,
     Error.validation("subagent assignment #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_string(nil, _field), do: :ok
  defp validate_optional_string(value, _field) when is_binary(value), do: :ok

  defp validate_optional_string(value, field) do
    {:error,
     Error.validation("subagent assignment #{field} must be a string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_strategy(strategy) when is_atom(strategy) do
    if strategy in StrategyRouter.strategies() do
      {:ok, strategy}
    else
      invalid_strategy(strategy)
    end
  end

  defp normalize_strategy(strategy) when is_binary(strategy) do
    StrategyRouter.strategies()
    |> Enum.find(&(Atom.to_string(&1) == strategy))
    |> case do
      nil -> invalid_strategy(strategy)
      strategy -> {:ok, strategy}
    end
  end

  defp normalize_strategy(strategy), do: invalid_strategy(strategy)

  defp invalid_strategy(strategy) do
    {:error,
     Error.validation("invalid subagent assignment strategy",
       source: __MODULE__,
       details: %{strategy: strategy, valid_strategies: StrategyRouter.strategies()}
     )}
  end

  defp normalize_agent_kind(kind) when kind in @agent_kinds, do: {:ok, kind}

  defp normalize_agent_kind(kind) when is_binary(kind) do
    @agent_kinds
    |> Enum.find(&(Atom.to_string(&1) == kind))
    |> case do
      nil -> invalid_agent_kind(kind)
      kind -> {:ok, kind}
    end
  end

  defp normalize_agent_kind(kind), do: invalid_agent_kind(kind)

  defp invalid_agent_kind(kind) do
    {:error,
     Error.validation("invalid subagent assignment agent kind",
       source: __MODULE__,
       details: %{agent_kind: kind, valid_agent_kinds: @agent_kinds}
     )}
  end

  defp normalize_context_slice(nil), do: {:ok, nil}

  defp normalize_context_slice(%ContextSliceContract{} = context_slice),
    do: ContextSliceContract.validate(context_slice)

  defp normalize_context_slice(context_slice) when is_map(context_slice), do: {:ok, context_slice}

  defp normalize_context_slice(context_slice) do
    {:error,
     Error.validation("subagent assignment context_slice must be a context contract, map, or nil",
       source: __MODULE__,
       details: %{context_slice: context_slice}
     )}
  end

  defp validate_capability_profile(nil), do: :ok
  defp validate_capability_profile(profile) when is_atom(profile), do: :ok
  defp validate_capability_profile(profile) when is_binary(profile) and profile != "", do: :ok

  defp validate_capability_profile(profile) do
    {:error,
     Error.validation("subagent assignment capability_profile must be an atom, string, or nil",
       source: __MODULE__,
       details: %{capability_profile: profile}
     )}
  end

  defp normalize_visible_tools(tools) when is_list(tools) do
    if Enum.all?(tools, &(is_binary(&1) or is_atom(&1))) do
      {:ok, Enum.map(tools, &to_string/1)}
    else
      {:error,
       Error.validation("subagent assignment visible_tools must contain only strings or atoms",
         source: __MODULE__,
         details: %{visible_tools: tools}
       )}
    end
  end

  defp normalize_visible_tools(tools) do
    {:error,
     Error.validation("subagent assignment visible_tools must be a list",
       source: __MODULE__,
       details: %{visible_tools: tools}
     )}
  end

  defp validate_budgets(budgets) when is_map(budgets), do: :ok

  defp validate_budgets(budgets) do
    {:error,
     Error.validation("subagent assignment budgets must be a map",
       source: __MODULE__,
       details: %{budgets: budgets}
     )}
  end

  defp validate_output_schema(schema) when is_map(schema), do: :ok

  defp validate_output_schema(schema) do
    {:error,
     Error.validation("subagent assignment output_schema must be a map",
       source: __MODULE__,
       details: %{output_schema: schema}
     )}
  end

  defp validate_optional_map(nil, _field), do: :ok
  defp validate_optional_map(value, _field) when is_map(value), do: :ok

  defp validate_optional_map(value, field) do
    {:error,
     Error.validation("subagent assignment #{field} must be a map or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_parent(nil), do: {:ok, nil}

  defp normalize_parent(parent) when is_list(parent) or is_map(parent) do
    parent = input_map(parent)
    depth = get(parent, :depth, 0)
    remaining_budgets = get(parent, :remaining_budgets, %{})

    with :ok <- validate_non_empty_string(get(parent, :run_id), :parent_run_id),
         {:ok, strategy} <- normalize_strategy(get(parent, :strategy)),
         {:ok, fallback} <- normalize_strategy(get(parent, :fallback)),
         :ok <- validate_non_negative_integer(depth, :parent_depth),
         :ok <- validate_budgets(remaining_budgets) do
      {:ok,
       %{
         run_id: get(parent, :run_id),
         strategy: strategy,
         depth: depth,
         fallback: fallback,
         remaining_budgets: remaining_budgets
       }}
    end
  end

  defp normalize_parent(parent) do
    {:error,
     Error.validation("subagent assignment parent must be a map, keyword list, or nil",
       source: __MODULE__,
       details: %{parent: parent}
     )}
  end

  defp validate_non_negative_integer(value, _field) when is_integer(value) and value >= 0,
    do: :ok

  defp validate_non_negative_integer(value, field) do
    {:error,
     Error.validation("subagent assignment #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("subagent assignment metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
