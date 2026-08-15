defmodule RunicAI.Decomposition.Assignment do
  @moduledoc """
  Materialized child invocation ready to execute or later resume.
  """

  alias RunicAI.Agent.State
  alias RunicAI.Decomposition.InheritancePolicy
  alias RunicAI.Decomposition.Role
  alias RunicAI.Decomposition.Task
  alias RunicAI.Error

  @enforce_keys [:id, :task, :role, :inheritance, :input, :resume_key, :metadata]
  defstruct [:id, :task, :role, :inheritance, :input, :seed_state, :resume_key, :metadata]

  @type t :: %__MODULE__{
          id: String.t(),
          task: Task.t(),
          role: Role.t(),
          inheritance: InheritancePolicy.t(),
          input: map(),
          seed_state: State.t() | nil,
          resume_key: String.t(),
          metadata: map()
        }

  @spec new(Task.t(), Role.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Task{} = task, %Role{} = role, opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id, "assignment:#{task.id}")
    input = Keyword.get(opts, :input, %{})
    seed_state = Keyword.get(opts, :seed_state)
    resume_key = Keyword.get(opts, :resume_key, default_resume_key(task.id))
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, task} <- Task.validate(task),
         {:ok, role} <- Role.validate(role),
         {:ok, inheritance} <- InheritancePolicy.from_input(Keyword.get(opts, :inheritance)),
         :ok <- validate_id(id),
         :ok <- validate_input(input),
         {:ok, seed_state} <- normalize_seed_state(seed_state),
         :ok <- validate_resume_key(resume_key),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         task: task,
         role: role,
         inheritance: inheritance,
         input: input,
         seed_state: seed_state,
         resume_key: resume_key,
         metadata: metadata
       }}
    end
  end

  @spec new!(Task.t(), Role.t(), keyword()) :: t()
  def new!(%Task{} = task, %Role{} = role, opts \\ []) do
    case new(task, role, opts) do
      {:ok, assignment} -> assignment
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = assignment) do
    new(assignment.task, assignment.role,
      id: assignment.id,
      inheritance: assignment.inheritance,
      input: assignment.input,
      seed_state: assignment.seed_state,
      resume_key: assignment.resume_key,
      metadata: assignment.metadata
    )
  end

  @spec from_input(t()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = assignment), do: validate(assignment)

  defp default_resume_key(task_id) do
    "child:#{task_id}:#{System.unique_integer([:positive])}"
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("decomposition assignment id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_input(input) when is_map(input), do: :ok

  defp validate_input(input) do
    {:error,
     Error.validation("decomposition assignment input must be a map",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  defp normalize_seed_state(nil), do: {:ok, nil}
  defp normalize_seed_state(%State{} = seed_state), do: State.validate(seed_state)

  defp normalize_seed_state(seed_state) do
    {:error,
     Error.validation("decomposition assignment seed_state must be an Agent.State or nil",
       source: __MODULE__,
       details: %{seed_state: seed_state}
     )}
  end

  defp validate_resume_key(resume_key) when is_binary(resume_key) and resume_key != "", do: :ok

  defp validate_resume_key(resume_key) do
    {:error,
     Error.validation("decomposition assignment resume_key must be a non-empty string",
       source: __MODULE__,
       details: %{resume_key: resume_key}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("decomposition assignment metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
