defmodule RunicAI.Context.Focus do
  @moduledoc """
  Goal and salience description for context selection and summarization.
  """

  alias RunicAI.Error

  @enforce_keys [:goal, :questions, :entities, :constraints, :metadata]
  defstruct [
    :goal,
    :time_scope,
    :salience_prompt,
    :metadata,
    questions: [],
    entities: [],
    constraints: []
  ]

  @type t :: %__MODULE__{
          goal: String.t(),
          questions: [String.t()],
          entities: [String.t()],
          constraints: [String.t()],
          time_scope: String.t() | nil,
          salience_prompt: String.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    goal = Keyword.get(opts, :goal, "")
    questions = Keyword.get(opts, :questions, [])
    entities = Keyword.get(opts, :entities, [])
    constraints = Keyword.get(opts, :constraints, [])
    time_scope = Keyword.get(opts, :time_scope)
    salience_prompt = Keyword.get(opts, :salience_prompt)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_goal(goal),
         :ok <- validate_string_list(:questions, questions),
         :ok <- validate_string_list(:entities, entities),
         :ok <- validate_string_list(:constraints, constraints),
         :ok <- validate_optional_string(:time_scope, time_scope),
         :ok <- validate_optional_string(:salience_prompt, salience_prompt),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         goal: goal,
         questions: questions,
         entities: entities,
         constraints: constraints,
         time_scope: time_scope,
         salience_prompt: salience_prompt,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, focus} -> focus
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = focus) do
    new(
      goal: focus.goal,
      questions: focus.questions,
      entities: focus.entities,
      constraints: focus.constraints,
      time_scope: focus.time_scope,
      salience_prompt: focus.salience_prompt,
      metadata: focus.metadata
    )
  end

  defp validate_goal(goal) when is_binary(goal) and goal != "", do: :ok

  defp validate_goal(goal) do
    {:error,
     Error.validation("context focus goal must be a non-empty string",
       source: __MODULE__,
       details: %{goal: goal}
     )}
  end

  defp validate_string_list(_field, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      :ok
    else
      {:error,
       Error.validation("context focus lists must contain only strings", source: __MODULE__)}
    end
  end

  defp validate_string_list(field, values) do
    {:error,
     Error.validation("context focus #{field} must be a list of strings",
       source: __MODULE__,
       details: %{field: field, values: values}
     )}
  end

  defp validate_optional_string(_field, nil), do: :ok
  defp validate_optional_string(_field, value) when is_binary(value), do: :ok

  defp validate_optional_string(field, value) do
    {:error,
     Error.validation("context focus #{field} must be a string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context focus metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
