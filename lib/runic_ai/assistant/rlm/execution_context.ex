defmodule RunicAI.Assistant.RLM.ExecutionContext do
  @moduledoc """
  Runtime context carried through generated assistant workflows.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @enforce_keys [:objective, :workspace]
  defstruct [
    :objective,
    :workspace,
    sources: [],
    outputs: %{},
    artifacts: [],
    trace: [],
    episodes: [],
    scorecards: [],
    budgets: %{},
    policies: %{},
    event_sink: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          objective: String.t(),
          workspace: Workspace.t(),
          sources: [map()],
          outputs: map(),
          artifacts: [map()],
          trace: [map()],
          episodes: [map()],
          scorecards: [map()],
          budgets: map(),
          policies: map(),
          event_sink: (map() -> term()) | nil,
          metadata: map()
        }

  @spec new(Workspace.t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(workspace, objective, opts \\ [])

  def new(%Workspace{} = workspace, objective, opts)
      when is_binary(objective) and objective != "" and is_list(opts) do
    sources = Keyword.get(opts, :sources, [])
    budgets = Keyword.get(opts, :budgets, %{})
    policies = Keyword.get(opts, :policies, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_list(sources, :sources),
         :ok <- validate_map(budgets, :budgets),
         :ok <- validate_map(policies, :policies),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         objective: objective,
         workspace: workspace,
         sources: sources,
         budgets: budgets,
         policies: policies,
         event_sink: Keyword.get(opts, :event_sink),
         metadata: metadata
       }}
    end
  end

  def new(_workspace, objective, _opts) do
    {:error,
     Error.validation("assistant execution context requires a workspace and non-empty objective",
       source: __MODULE__,
       details: %{objective: objective}
     )}
  end

  @spec new!(Workspace.t(), String.t(), keyword()) :: t()
  def new!(%Workspace{} = workspace, objective, opts \\ []) do
    case new(workspace, objective, opts) do
      {:ok, context} -> context
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("execution context #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("execution context #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
