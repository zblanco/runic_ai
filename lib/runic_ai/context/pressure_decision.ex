defmodule RunicAI.Context.PressureDecision do
  @moduledoc """
  Explicit next action when the active bundle approaches or exceeds the window.
  """

  alias RunicAI.Context.PressureSnapshot
  alias RunicAI.Error

  @valid_actions [:none, :compact, :handoff, :retrieve, :review]

  @enforce_keys [:action, :reason, :snapshot, :metadata]
  defstruct [:action, :reason, :snapshot, :metadata]

  @type action :: :none | :compact | :handoff | :retrieve | :review

  @type t :: %__MODULE__{
          action: action(),
          reason: String.t(),
          snapshot: PressureSnapshot.t(),
          metadata: map()
        }

  @spec new(action(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(action, reason, opts \\ []) when is_list(opts) do
    snapshot = Keyword.get(opts, :snapshot, PressureSnapshot.new!())
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_action(action),
         :ok <- validate_reason(reason),
         {:ok, snapshot} <- PressureSnapshot.validate(snapshot),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{action: action, reason: reason, snapshot: snapshot, metadata: metadata}}
    end
  end

  @spec new!(action(), String.t(), keyword()) :: t()
  def new!(action, reason, opts \\ []) do
    case new(action, reason, opts) do
      {:ok, decision} -> decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = decision) do
    new(decision.action, decision.reason,
      snapshot: decision.snapshot,
      metadata: decision.metadata
    )
  end

  defp validate_action(action) when action in @valid_actions, do: :ok

  defp validate_action(action) do
    {:error,
     Error.validation("invalid context pressure action: #{inspect(action)}",
       source: __MODULE__,
       details: %{action: action, valid_actions: @valid_actions}
     )}
  end

  defp validate_reason(reason) when is_binary(reason) and reason != "", do: :ok

  defp validate_reason(reason) do
    {:error,
     Error.validation("context pressure reason must be a non-empty string",
       source: __MODULE__,
       details: %{reason: reason}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context pressure metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
