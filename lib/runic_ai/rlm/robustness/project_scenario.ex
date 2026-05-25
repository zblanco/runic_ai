defmodule RunicAI.RLM.Robustness.ProjectScenario do
  @moduledoc """
  Project-generation robustness scenario for RLM capability testing.
  """

  alias RunicAI.Error

  @enforce_keys [
    :id,
    :title,
    :prompt,
    :workspace_factory,
    :lanes,
    :deterministic_checks,
    :judge_rubric,
    :browser_user_story,
    :browser_validation_tasks,
    :metadata
  ]
  @derive Jason.Encoder
  defstruct [
    :id,
    :title,
    :prompt,
    workspace_factory: :mix_project,
    lanes: [:standard, :assistant, :rlm, :browser_tidewave],
    deterministic_checks: [],
    judge_rubric: %{},
    browser_user_story: nil,
    browser_validation_tasks: [],
    required_commands: [],
    runtime_smokes: [],
    tags: [],
    budgets: %{max_runtime_ms: 1_800_000, max_repairs: 2},
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    id = Keyword.get(opts, :id)
    title = Keyword.get(opts, :title)
    prompt = Keyword.get(opts, :prompt)
    workspace_factory = Keyword.get(opts, :workspace_factory, :mix_project)
    lanes = Keyword.get(opts, :lanes, [:standard, :assistant, :rlm, :browser_tidewave])
    checks = Keyword.get(opts, :deterministic_checks, [])
    judge_rubric = Keyword.get(opts, :judge_rubric, %{})
    browser_user_story = Keyword.get(opts, :browser_user_story)
    browser_validation_tasks = Keyword.get(opts, :browser_validation_tasks, [])
    required_commands = Keyword.get(opts, :required_commands, [])
    runtime_smokes = Keyword.get(opts, :runtime_smokes, [])
    tags = Keyword.get(opts, :tags, [])
    budgets = Keyword.get(opts, :budgets, %{max_runtime_ms: 1_800_000, max_repairs: 2})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- non_empty_string(id, :id),
         :ok <- non_empty_string(title, :title),
         :ok <- non_empty_string(prompt, :prompt),
         :ok <- atom_value(workspace_factory, :workspace_factory),
         :ok <- atom_list(lanes, :lanes),
         :ok <- list_value(checks, :deterministic_checks),
         :ok <- map_value(judge_rubric, :judge_rubric),
         :ok <- non_empty_string(browser_user_story, :browser_user_story),
         :ok <- string_list(browser_validation_tasks, :browser_validation_tasks),
         :ok <- list_value(required_commands, :required_commands),
         :ok <- list_value(runtime_smokes, :runtime_smokes),
         :ok <- string_list(tags, :tags),
         :ok <- map_value(budgets, :budgets),
         :ok <- map_value(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         title: title,
         prompt: prompt,
         workspace_factory: workspace_factory,
         lanes: lanes,
         deterministic_checks: checks,
         judge_rubric: judge_rubric,
         browser_user_story: browser_user_story,
         browser_validation_tasks: browser_validation_tasks,
         required_commands: required_commands,
         runtime_smokes: runtime_smokes,
         tags: tags,
         budgets: budgets,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, scenario} -> scenario
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec ids([t()]) :: [String.t()]
  def ids(scenarios), do: Enum.map(scenarios, & &1.id)

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    validation_error("#{field} must be a non-empty string", field, value)
  end

  defp atom_value(value, _field) when is_atom(value), do: :ok
  defp atom_value(value, field), do: validation_error("#{field} must be an atom", field, value)

  defp atom_list(values, field) when is_list(values) do
    if Enum.all?(values, &is_atom/1) do
      :ok
    else
      validation_error("#{field} must be a list of atoms", field, values)
    end
  end

  defp atom_list(value, field), do: validation_error("#{field} must be a list", field, value)

  defp string_list(values, field) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      :ok
    else
      validation_error("#{field} must be a list of strings", field, values)
    end
  end

  defp string_list(value, field), do: validation_error("#{field} must be a list", field, value)

  defp list_value(value, _field) when is_list(value), do: :ok
  defp list_value(value, field), do: validation_error("#{field} must be a list", field, value)

  defp map_value(value, _field) when is_map(value), do: :ok
  defp map_value(value, field), do: validation_error("#{field} must be a map", field, value)

  defp validation_error(message, field, value) do
    {:error,
     Error.validation(message, source: __MODULE__, details: %{field: field, value: value})}
  end
end
