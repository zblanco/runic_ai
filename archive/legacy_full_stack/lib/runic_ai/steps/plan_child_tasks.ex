defmodule RunicAI.Steps.PlanChildTasks do
  @moduledoc """
  Normalize planner output into a `RunicAI.Decomposition.TaskPlan`.
  """

  require Runic

  alias RunicAI.Decomposition.Callable
  alias RunicAI.Decomposition.TaskPlan

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :plan_child_tasks)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        plan!(input, defaults)
      end,
      name: name
    )
  end

  @spec plan(TaskPlan.t() | [term()] | map() | nil, keyword()) ::
          {:ok, TaskPlan.t()} | {:error, RunicAI.Error.t()}
  def plan(input, opts \\ []) when is_list(opts) do
    with {:ok, planned_input} <- resolve_planned_input(input, Keyword.get(opts, :planner)),
         {:ok, task_source, plan_opts} <- normalize_plan_source(planned_input, input, opts),
         {:ok, task_plan} <- TaskPlan.from_input(task_source, plan_opts) do
      {:ok, task_plan}
    end
  end

  @spec plan!(TaskPlan.t() | [term()] | map() | nil, keyword()) :: TaskPlan.t()
  def plan!(input, opts \\ []) do
    case plan(input, opts) do
      {:ok, task_plan} -> task_plan
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp resolve_planned_input(input, nil), do: {:ok, input}

  defp resolve_planned_input(input, planner) do
    case Callable.validate(planner, "child task planner", __MODULE__) do
      :ok -> {:ok, Callable.invoke(planner, input)}
      error -> error
    end
  end

  defp normalize_plan_source(%TaskPlan{} = task_plan, _original_input, opts) do
    {:ok, task_plan, merge_plan_opts([], opts)}
  end

  defp normalize_plan_source(plan_map, _original_input, opts) when is_map(plan_map) do
    cond do
      plan_entry = map_get(plan_map, :task_plan) ->
        {:ok, plan_entry, merge_plan_opts(plan_map, opts)}

      tasks = map_get(plan_map, :tasks) ->
        {:ok, tasks, merge_plan_opts(plan_map, opts)}

      true ->
        {:ok, plan_map, merge_plan_opts([], opts)}
    end
  end

  defp normalize_plan_source(nil, _original_input, opts) do
    {:ok, Keyword.get(opts, :tasks), merge_plan_opts([], opts)}
  end

  defp normalize_plan_source(other, _original_input, opts) do
    {:ok, other, merge_plan_opts([], opts)}
  end

  defp merge_plan_opts(source, opts) do
    metadata =
      Keyword.get(opts, :metadata, %{})
      |> Map.merge(normalize_metadata(map_get(source, :metadata)))

    []
    |> maybe_put(:groups, map_get(source, :groups) || Keyword.get(opts, :groups))
    |> maybe_put(:join_policy, map_get(source, :join_policy) || Keyword.get(opts, :join_policy))
    |> Keyword.put(:metadata, metadata)
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp map_get(source, key) when is_map(source) do
    Map.get(source, key) || Map.get(source, Atom.to_string(key))
  end

  defp map_get(_source, _key), do: nil
end
