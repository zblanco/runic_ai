defmodule RunicAI.Decomposition.Task do
  @moduledoc """
  One scoped unit of delegated work.
  """

  alias RunicAI.Context.Bundle
  alias RunicAI.Context.HandoffArtifact
  alias RunicAI.Decomposition.Role
  alias RunicAI.Error

  @enforce_keys [:id, :goal, :role, :priority, :depends_on, :metadata]
  defstruct [
    :id,
    :goal,
    :role,
    :instructions,
    :input,
    :handoff,
    :context_bundle,
    :output_contract,
    :priority,
    :depends_on,
    :metadata
  ]

  @type role_ref :: String.t() | Role.t()

  @type t :: %__MODULE__{
          id: String.t(),
          goal: String.t(),
          role: role_ref(),
          instructions: String.t() | nil,
          input: term(),
          handoff: HandoffArtifact.t() | nil,
          context_bundle: Bundle.t() | nil,
          output_contract: map() | keyword() | nil,
          priority: non_neg_integer(),
          depends_on: [String.t()],
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id, default_id())
    goal = Keyword.get(opts, :goal)
    role = Keyword.get(opts, :role)
    instructions = Keyword.get(opts, :instructions)
    handoff = Keyword.get(opts, :handoff)
    context_bundle = Keyword.get(opts, :context_bundle)
    output_contract = Keyword.get(opts, :output_contract)
    priority = Keyword.get(opts, :priority, 0)
    depends_on = Keyword.get(opts, :depends_on, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_goal(goal),
         {:ok, role} <- normalize_role(role),
         :ok <- validate_optional_string(:instructions, instructions),
         {:ok, handoff} <- normalize_handoff(handoff),
         {:ok, context_bundle} <- normalize_context_bundle(context_bundle),
         :ok <- validate_output_contract(output_contract),
         :ok <- validate_priority(priority),
         :ok <- validate_depends_on(depends_on),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         goal: goal,
         role: role,
         instructions: instructions,
         input: Keyword.get(opts, :input),
         handoff: handoff,
         context_bundle: context_bundle,
         output_contract: output_contract,
         priority: priority,
         depends_on: depends_on,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, task} -> task
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = task) do
    new(
      id: task.id,
      goal: task.goal,
      role: task.role,
      instructions: task.instructions,
      input: task.input,
      handoff: task.handoff,
      context_bundle: task.context_bundle,
      output_contract: task.output_contract,
      priority: task.priority,
      depends_on: task.depends_on,
      metadata: task.metadata
    )
  end

  @spec from_input(t() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = task), do: validate(task)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(other) do
    {:error,
     Error.validation("expected a Decomposition.Task-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | keyword()) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, task} -> task
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp default_id do
    "task:#{System.unique_integer([:positive])}"
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("decomposition task id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_goal(goal) when is_binary(goal) and goal != "", do: :ok

  defp validate_goal(goal) do
    {:error,
     Error.validation("decomposition task goal must be a non-empty string",
       source: __MODULE__,
       details: %{goal: goal}
     )}
  end

  defp normalize_role(%Role{} = role), do: Role.validate(role)

  defp normalize_role(role) when is_binary(role) and role != "" do
    {:ok, role}
  end

  defp normalize_role(role) do
    {:error,
     Error.validation("decomposition task role must be a role name or Role struct",
       source: __MODULE__,
       details: %{role: role}
     )}
  end

  defp validate_optional_string(_field, nil), do: :ok
  defp validate_optional_string(_field, value) when is_binary(value), do: :ok

  defp validate_optional_string(field, value) do
    {:error,
     Error.validation("decomposition task #{field} must be a string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_handoff(nil), do: {:ok, nil}
  defp normalize_handoff(%HandoffArtifact{} = handoff), do: HandoffArtifact.validate(handoff)

  defp normalize_handoff(handoff) do
    {:error,
     Error.validation("decomposition task handoff must be a HandoffArtifact or nil",
       source: __MODULE__,
       details: %{handoff: handoff}
     )}
  end

  defp normalize_context_bundle(nil), do: {:ok, nil}
  defp normalize_context_bundle(%Bundle{} = bundle), do: Bundle.validate(bundle)

  defp normalize_context_bundle(context_bundle) do
    {:error,
     Error.validation("decomposition task context_bundle must be a Bundle or nil",
       source: __MODULE__,
       details: %{context_bundle: context_bundle}
     )}
  end

  defp validate_output_contract(nil), do: :ok
  defp validate_output_contract(contract) when is_map(contract), do: :ok
  defp validate_output_contract(contract) when is_list(contract), do: :ok

  defp validate_output_contract(contract) do
    {:error,
     Error.validation("decomposition task output_contract must be a map, keyword list, or nil",
       source: __MODULE__,
       details: %{output_contract: contract}
     )}
  end

  defp validate_priority(priority) when is_integer(priority) and priority >= 0, do: :ok

  defp validate_priority(priority) do
    {:error,
     Error.validation("decomposition task priority must be a non-negative integer",
       source: __MODULE__,
       details: %{priority: priority}
     )}
  end

  defp validate_depends_on(depends_on) when is_list(depends_on) do
    if Enum.all?(depends_on, &is_binary/1) do
      :ok
    else
      {:error,
       Error.validation("decomposition task depends_on must contain only task ids",
         source: __MODULE__,
         details: %{depends_on: depends_on}
       )}
    end
  end

  defp validate_depends_on(depends_on) do
    {:error,
     Error.validation("decomposition task depends_on must be a list",
       source: __MODULE__,
       details: %{depends_on: depends_on}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("decomposition task metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
