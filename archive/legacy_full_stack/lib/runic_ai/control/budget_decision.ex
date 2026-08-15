defmodule RunicAI.Control.BudgetDecision do
  @moduledoc """
  Result of evaluating a budget snapshot against a budget policy.
  """

  alias RunicAI.Control.BudgetSnapshot
  alias RunicAI.Error

  @valid_statuses [:within_limits, :soft_limit, :exhausted]
  @valid_actions [:continue, :halt, :review, :wait]

  @enforce_keys [:status, :action, :reasons, :snapshot, :metadata]
  defstruct [:status, :action, :reasons, :snapshot, :metadata]

  @type status :: :within_limits | :soft_limit | :exhausted
  @type action :: :continue | :halt | :review | :wait

  @type t :: %__MODULE__{
          status: status(),
          action: action(),
          reasons: [map()],
          snapshot: BudgetSnapshot.t(),
          metadata: map()
        }

  @spec new(status(), action(), BudgetSnapshot.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(status, action, %BudgetSnapshot{} = snapshot, opts \\ []) when is_list(opts) do
    reasons = Keyword.get(opts, :reasons, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_status(status),
         :ok <- validate_action(action),
         {:ok, snapshot} <- BudgetSnapshot.validate(snapshot),
         :ok <- validate_reasons(reasons),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         status: status,
         action: action,
         reasons: reasons,
         snapshot: snapshot,
         metadata: metadata
       }}
    end
  end

  @spec new!(status(), action(), BudgetSnapshot.t(), keyword()) :: t()
  def new!(status, action, %BudgetSnapshot{} = snapshot, opts \\ []) do
    case new(status, action, snapshot, opts) do
      {:ok, budget_decision} -> budget_decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = budget_decision) do
    new(budget_decision.status, budget_decision.action, budget_decision.snapshot,
      reasons: budget_decision.reasons,
      metadata: budget_decision.metadata
    )
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid budget decision status: #{inspect(status)}",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_action(action) when action in @valid_actions, do: :ok

  defp validate_action(action) do
    {:error,
     Error.validation("invalid budget decision action: #{inspect(action)}",
       source: __MODULE__,
       details: %{action: action, valid_actions: @valid_actions}
     )}
  end

  defp validate_reasons(reasons) when is_list(reasons), do: :ok

  defp validate_reasons(reasons) do
    {:error,
     Error.validation("budget decision reasons must be a list, got: #{inspect(reasons)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("budget decision metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
