defmodule RunicAI.Context.HandoffArtifact do
  @moduledoc """
  Focused artifact used to seed a new thread or child workflow.
  """

  alias RunicAI.Context.Ref
  alias RunicAI.Error
  alias RunicAI.Message

  @enforce_keys [
    :brief,
    :seed_messages,
    :references,
    :open_questions,
    :next_actions,
    :constraints,
    :metadata
  ]
  defstruct [
    :brief,
    :seed_messages,
    :references,
    :open_questions,
    :next_actions,
    :constraints,
    :metadata
  ]

  @type t :: %__MODULE__{
          brief: String.t(),
          seed_messages: [Message.t()],
          references: [Ref.t()],
          open_questions: [String.t()],
          next_actions: [String.t()],
          constraints: [String.t()],
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    brief = Keyword.get(opts, :brief, "")
    seed_messages = Keyword.get(opts, :seed_messages, [])
    references = Keyword.get(opts, :references, [])
    open_questions = Keyword.get(opts, :open_questions, [])
    next_actions = Keyword.get(opts, :next_actions, [])
    constraints = Keyword.get(opts, :constraints, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_string(:brief, brief),
         {:ok, seed_messages} <- Message.normalize_list(seed_messages),
         {:ok, references} <- normalize_refs(references),
         :ok <- validate_string_list(:open_questions, open_questions),
         :ok <- validate_string_list(:next_actions, next_actions),
         :ok <- validate_string_list(:constraints, constraints),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         brief: brief,
         seed_messages: seed_messages,
         references: references,
         open_questions: open_questions,
         next_actions: next_actions,
         constraints: constraints,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, artifact} -> artifact
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = artifact) do
    new(
      brief: artifact.brief,
      seed_messages: artifact.seed_messages,
      references: artifact.references,
      open_questions: artifact.open_questions,
      next_actions: artifact.next_actions,
      constraints: artifact.constraints,
      metadata: artifact.metadata
    )
  end

  defp validate_string(_field, value) when is_binary(value) and value != "", do: :ok

  defp validate_string(field, value) do
    {:error,
     Error.validation("handoff artifact #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_string_list(_field, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      :ok
    else
      {:error,
       Error.validation("handoff artifact lists must contain only strings", source: __MODULE__)}
    end
  end

  defp validate_string_list(field, values) do
    {:error,
     Error.validation("handoff artifact #{field} must be a list of strings",
       source: __MODULE__,
       details: %{field: field, values: values}
     )}
  end

  defp normalize_refs(refs) when is_list(refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case Ref.validate(ref) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_refs(refs) do
    {:error,
     Error.validation("handoff artifact references must be a list of Context.Ref structs",
       source: __MODULE__,
       details: %{references: refs}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("handoff artifact metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
