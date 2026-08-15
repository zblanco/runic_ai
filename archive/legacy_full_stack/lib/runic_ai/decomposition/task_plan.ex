defmodule RunicAI.Decomposition.TaskPlan do
  @moduledoc """
  Planned set of child tasks and their intended execution grouping.
  """

  alias RunicAI.Decomposition.JoinPolicy
  alias RunicAI.Decomposition.Task
  alias RunicAI.Error

  @enforce_keys [:tasks, :join_policy, :metadata]
  defstruct [:tasks, :groups, :join_policy, :metadata]

  @type group_item :: String.t()

  @type t :: %__MODULE__{
          tasks: [Task.t()],
          groups: [[group_item()]] | nil,
          join_policy: JoinPolicy.t(),
          metadata: map()
        }

  @spec new([Task.t() | keyword()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(tasks \\ [], opts \\ []) when is_list(tasks) and is_list(opts) do
    groups = Keyword.get(opts, :groups)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_tasks} <- normalize_tasks(tasks),
         {:ok, join_policy} <- JoinPolicy.from_input(Keyword.get(opts, :join_policy)),
         {:ok, groups} <- normalize_groups(groups, normalized_tasks),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         tasks: normalized_tasks,
         groups: groups,
         join_policy: join_policy,
         metadata: metadata
       }}
    end
  end

  @spec new!([Task.t() | keyword()], keyword()) :: t()
  def new!(tasks \\ [], opts \\ []) do
    case new(tasks, opts) do
      {:ok, task_plan} -> task_plan
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = task_plan) do
    new(task_plan.tasks,
      groups: task_plan.groups,
      join_policy: task_plan.join_policy,
      metadata: task_plan.metadata
    )
  end

  @spec from_input(t() | [Task.t() | keyword()] | nil, keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def from_input(input, opts \\ [])

  def from_input(nil, opts), do: new([], opts)
  def from_input(%__MODULE__{} = task_plan, _opts), do: validate(task_plan)
  def from_input(tasks, opts) when is_list(tasks), do: new(tasks, opts)

  def from_input(other, _opts) do
    {:error,
     Error.validation("expected a TaskPlan-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | [Task.t() | keyword()] | nil, keyword()) :: t()
  def from_input!(input, opts \\ []) do
    case from_input(input, opts) do
      {:ok, task_plan} -> task_plan
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{tasks: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @spec task_ids(t()) :: [String.t()]
  def task_ids(%__MODULE__{tasks: tasks}), do: Enum.map(tasks, & &1.id)

  defp normalize_tasks(tasks) do
    tasks
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, acc} ->
      case Task.from_input(task) do
        {:ok, normalized_task} -> {:cont, {:ok, [normalized_task | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_tasks} ->
        normalized_tasks = Enum.reverse(normalized_tasks)

        case validate_unique_ids(normalized_tasks) do
          :ok -> {:ok, normalized_tasks}
          error -> error
        end

      error ->
        error
    end
  end

  defp validate_unique_ids(tasks) do
    ids = Enum.map(tasks, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      duplicates ->
        {:error,
         Error.validation("decomposition task ids must be unique inside a task plan",
           source: __MODULE__,
           details: %{duplicate_task_ids: duplicates}
         )}
    end
  end

  defp normalize_groups(nil, _tasks), do: {:ok, nil}

  defp normalize_groups(groups, tasks) when is_list(groups) do
    task_ids = MapSet.new(Enum.map(tasks, & &1.id))

    groups
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, acc} ->
      case normalize_group(group, task_ids) do
        {:ok, normalized_group} -> {:cont, {:ok, [normalized_group | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_groups} -> {:ok, Enum.reverse(normalized_groups)}
      error -> error
    end
  end

  defp normalize_groups(groups, _tasks) do
    {:error,
     Error.validation("decomposition task groups must be nil or a list of lists",
       source: __MODULE__,
       details: %{groups: groups}
     )}
  end

  defp normalize_group(group, task_ids) when is_list(group) do
    group
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize_group_item(item, task_ids) do
        {:ok, normalized_item} -> {:cont, {:ok, [normalized_item | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_group} -> {:ok, Enum.reverse(normalized_group)}
      error -> error
    end
  end

  defp normalize_group(group, _task_ids) do
    {:error,
     Error.validation("decomposition task groups must contain only lists",
       source: __MODULE__,
       details: %{group: group}
     )}
  end

  defp normalize_group_item(%Task{} = task, task_ids) do
    with {:ok, task} <- Task.validate(task),
         :ok <- ensure_task_in_plan(task.id, task_ids) do
      {:ok, task.id}
    end
  end

  defp normalize_group_item(task_id, task_ids) when is_binary(task_id) do
    with :ok <- ensure_task_in_plan(task_id, task_ids) do
      {:ok, task_id}
    end
  end

  defp normalize_group_item(item, _task_ids) do
    {:error,
     Error.validation("decomposition task groups must reference task ids or Task structs",
       source: __MODULE__,
       details: %{group_item: item}
     )}
  end

  defp ensure_task_in_plan(task_id, task_ids) do
    if MapSet.member?(task_ids, task_id) do
      :ok
    else
      {:error,
       Error.validation("decomposition task group references an unknown task id",
         source: __MODULE__,
         details: %{task_id: task_id}
       )}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("decomposition task plan metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
