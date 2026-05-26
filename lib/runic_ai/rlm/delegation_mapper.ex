defmodule RunicAI.RLM.DelegationMapper do
  @moduledoc """
  Builds map-style subagent assignments over context slices.

  This is still a planning layer. It fans out validated context slices into
  `SubagentAssignment` records that can later be executed by a standard-agent,
  workflow, REPL, or generated-component adapter.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.ContextSliceContract
  alias RunicAI.RLM.StrategyRouter
  alias RunicAI.RLM.SubagentAssignment

  @spec map_slices([ContextSliceContract.t() | map()], keyword() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def map_slices(context_slices, opts \\ [])

  def map_slices(context_slices, opts) when is_list(context_slices) do
    opts = opts_map(opts)

    with {:ok, context_slices} <- validate_context_slices(context_slices),
         :ok <- validate_required(opts, :role),
         :ok <- validate_required(opts, :objective_template),
         {:ok, strategy} <- normalize_strategy(opt(opts, :strategy, :subagent_delegation)) do
      assignments =
        context_slices
        |> Enum.with_index(1)
        |> Enum.map(fn {context_slice, index} ->
          SubagentAssignment.new!(
            id: assignment_id(context_slice, index, opts),
            role: role_for(context_slice, opts),
            objective: objective_for(context_slice, index, opts),
            prompt: prompt_for(context_slice, index, opts),
            strategy: strategy,
            agent_kind: opt(opts, :agent_kind, nil),
            context_slice: context_slice,
            capability_profile: opt(opts, :capability_profile, nil),
            visible_tools: opt(opts, :visible_tools, []),
            budgets: budget_for(context_slice, opts),
            output_schema: output_schema_for(context_slice, opts),
            review_policy: review_policy_for(context_slice, opts),
            parent: opt(opts, :parent, nil),
            metadata:
              metadata_for(context_slice, index, opts)
              |> Map.merge(%{mapper: __MODULE__, map_index: index})
          )
        end)

      {:ok,
       %{
         strategy: strategy,
         assignments: assignments,
         count: length(assignments),
         context_slice_count: length(context_slices),
         parent: opt(opts, :parent, nil)
       }}
    end
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  def map_slices(context_slices, _opts) do
    {:error,
     Error.validation("delegation mapper requires a list of context slices",
       source: __MODULE__,
       details: %{context_slices: context_slices}
     )}
  end

  defp validate_context_slices(slices) do
    Enum.reduce_while(slices, {:ok, []}, fn slice, {:ok, acc} ->
      case ContextSliceContract.from_input(slice) do
        {:ok, slice} -> {:cont, {:ok, acc ++ [slice]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_required(opts, key) do
    case opt(opts, key, nil) do
      value when is_binary(value) and value != "" ->
        :ok

      value ->
        {:error,
         Error.validation("delegation mapper requires #{key}",
           source: __MODULE__,
           details: %{field: key, value: value}
         )}
    end
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
     Error.validation("invalid delegation mapper strategy",
       source: __MODULE__,
       details: %{strategy: strategy, valid_strategies: StrategyRouter.strategies()}
     )}
  end

  defp assignment_id(%ContextSliceContract{} = slice, index, opts) do
    prefix = opt(opts, :id_prefix, "assignment")
    "#{prefix}:#{index}:#{slice.id}"
  end

  defp role_for(%ContextSliceContract{} = slice, opts) do
    slice.metadata[:review_role] || slice.metadata["review_role"] || opt(opts, :role, nil)
  end

  defp objective_for(%ContextSliceContract{} = slice, index, opts) do
    opts
    |> opt(:objective_template, "")
    |> render_template(slice, index)
  end

  defp prompt_for(%ContextSliceContract{} = slice, index, opts) do
    case opt(opts, :prompt_template, nil) do
      nil -> nil
      template -> render_template(template, slice, index)
    end
  end

  defp budget_for(%ContextSliceContract{} = slice, opts) do
    opts
    |> map_opt(:budgets, %{})
    |> Map.merge(%{
      context_byte_budget: slice.byte_budget,
      context_token_budget: slice.token_budget
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp output_schema_for(%ContextSliceContract{} = slice, opts) do
    opt(opts, :output_schema, slice.expected_output_schema || %{})
  end

  defp review_policy_for(%ContextSliceContract{} = slice, opts) do
    opt(opts, :review_policy, slice.review_policy || %{})
  end

  defp metadata_for(%ContextSliceContract{} = slice, _index, opts) do
    opts
    |> map_opt(:metadata, %{})
    |> Map.merge(%{
      context_slice_id: slice.id,
      context_source_kind: slice.source_kind,
      context_source_ref: slice.source_ref.source_id
    })
  end

  defp render_template(template, %ContextSliceContract{} = slice, index)
       when is_binary(template) do
    replacements = %{
      "slice_id" => slice.id,
      "slice_index" => Integer.to_string(index),
      "source_kind" => Atom.to_string(slice.source_kind),
      "source_ref" => slice.source_ref.source_id,
      "role" => slice.metadata[:review_role] || slice.metadata["review_role"] || ""
    }

    Enum.reduce(replacements, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)

  defp opt(opts, key, default) do
    opts = opts_map(opts)
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp map_opt(opts, key, default) do
    case opt(opts, key, default) do
      value when is_map(value) -> value
      value when is_list(value) -> Map.new(value)
      _other -> default
    end
  end
end
