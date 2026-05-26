defmodule RunicAI.RLM.REPL.EnvironmentFunction do
  @moduledoc """
  Descriptor for a mediated function exposed inside an RLM REPL environment.

  These descriptors are not executable callbacks. They are the contract the
  runtime uses to decide which functions may be injected into a sandbox REPL and
  which budget/review surface each function belongs to.
  """

  alias RunicAI.Error

  @default_functions [
    %{
      name: "peek",
      arity: 2,
      kind: :context_read,
      budget_key: :environment_reads,
      review_required?: false,
      description: "Return a bounded preview of an external context handle."
    },
    %{
      name: "read_slice",
      arity: 3,
      kind: :context_read,
      budget_key: :environment_reads,
      review_required?: false,
      description: "Read one bounded context slice by offset and length."
    },
    %{
      name: "write_artifact",
      arity: 2,
      kind: :artifact_write,
      budget_key: :artifact_writes,
      review_required?: true,
      description: "Write a structured artifact into sandbox-managed state."
    },
    %{
      name: "llm_query",
      arity: 2,
      kind: :model_call,
      budget_key: :llm_queries,
      review_required?: false,
      description: "Run one bounded model subquery through RunicAI mediation."
    },
    %{
      name: "rlm_query",
      arity: 3,
      kind: :recursive_call,
      budget_key: :rlm_queries,
      review_required?: false,
      description: "Run a recursive subproblem through a mediated RLM strategy."
    },
    %{
      name: "delegate",
      arity: 3,
      kind: :subagent_call,
      budget_key: :delegations,
      review_required?: false,
      description: "Delegate a bounded task to a scoped subagent."
    },
    %{
      name: "checkpoint",
      arity: 1,
      kind: :sandbox_checkpoint,
      budget_key: :checkpoints,
      review_required?: true,
      description: "Create a sandbox checkpoint for REPL state."
    },
    %{
      name: "set_final",
      arity: 1,
      kind: :finalize,
      budget_key: nil,
      review_required?: false,
      description: "Set the structured final result and stop the REPL loop."
    }
  ]

  @kinds [
    :context_read,
    :artifact_write,
    :model_call,
    :recursive_call,
    :subagent_call,
    :sandbox_checkpoint,
    :finalize
  ]

  @enforce_keys [:name, :arity, :kind, :review_required?, :metadata]
  defstruct [
    :name,
    :arity,
    :kind,
    :budget_key,
    :review_required?,
    :description,
    metadata: %{}
  ]

  @type kind ::
          :context_read
          | :artifact_write
          | :model_call
          | :recursive_call
          | :subagent_call
          | :sandbox_checkpoint
          | :finalize

  @type t :: %__MODULE__{
          name: String.t(),
          arity: non_neg_integer(),
          kind: kind(),
          budget_key: atom() | nil,
          review_required?: boolean(),
          description: String.t() | nil,
          metadata: map()
        }

  @spec default_functions() :: [t()]
  def default_functions do
    Enum.map(@default_functions, &new!/1)
  end

  @spec default_names() :: [String.t()]
  def default_names, do: Enum.map(default_functions(), & &1.name)

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    name = get(attrs, :name, nil)
    arity = get(attrs, :arity, nil)
    kind = get(attrs, :kind, nil)
    budget_key = get(attrs, :budget_key, nil)
    review_required? = get(attrs, :review_required?, false)
    description = get(attrs, :description, nil)
    metadata = get(attrs, :metadata, %{})

    with :ok <- validate_name(name),
         :ok <- validate_arity(arity),
         {:ok, kind} <- normalize_kind(kind),
         :ok <- validate_budget_key(budget_key),
         :ok <- validate_review_required(review_required?),
         :ok <- validate_description(description),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         name: name,
         arity: arity,
         kind: kind,
         budget_key: budget_key,
         review_required?: review_required?,
         description: description,
         metadata: metadata
       }}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, function} -> function
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = function) do
    new(Map.from_struct(function))
  end

  defp validate_name(name) when is_binary(name) and name != "", do: :ok

  defp validate_name(name) do
    {:error,
     Error.validation("REPL environment function name must be a non-empty string",
       source: __MODULE__,
       details: %{name: name}
     )}
  end

  defp validate_arity(arity) when is_integer(arity) and arity >= 0, do: :ok

  defp validate_arity(arity) do
    {:error,
     Error.validation("REPL environment function arity must be a non-negative integer",
       source: __MODULE__,
       details: %{arity: arity}
     )}
  end

  defp normalize_kind(kind) when kind in @kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    Enum.find(@kinds, &(Atom.to_string(&1) == kind))
    |> case do
      nil -> invalid_kind(kind)
      kind -> {:ok, kind}
    end
  end

  defp normalize_kind(kind), do: invalid_kind(kind)

  defp invalid_kind(kind) do
    {:error,
     Error.validation("invalid REPL environment function kind",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @kinds}
     )}
  end

  defp validate_budget_key(nil), do: :ok
  defp validate_budget_key(key) when is_atom(key), do: :ok

  defp validate_budget_key(key) do
    {:error,
     Error.validation("REPL environment function budget_key must be an atom or nil",
       source: __MODULE__,
       details: %{budget_key: key}
     )}
  end

  defp validate_review_required(value) when is_boolean(value), do: :ok

  defp validate_review_required(value) do
    {:error,
     Error.validation("REPL environment function review_required? must be boolean",
       source: __MODULE__,
       details: %{review_required?: value}
     )}
  end

  defp validate_description(nil), do: :ok
  defp validate_description(value) when is_binary(value), do: :ok

  defp validate_description(value) do
    {:error,
     Error.validation("REPL environment function description must be a string or nil",
       source: __MODULE__,
       details: %{description: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("REPL environment function metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
