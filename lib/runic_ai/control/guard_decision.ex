defmodule RunicAI.Control.GuardDecision do
  @moduledoc """
  Result of evaluating a guard request at a control point.
  """

  alias RunicAI.Error

  @valid_actions [:allow, :deny, :review, :wait, :rewrite]

  @enforce_keys [:action, :reason, :details, :metadata]
  defstruct [:action, :reason, :replacement, :details, :metadata]

  @type action :: :allow | :deny | :review | :wait | :rewrite

  @type t :: %__MODULE__{
          action: action(),
          reason: atom() | String.t(),
          replacement: term(),
          details: map(),
          metadata: map()
        }

  @spec new(action(), atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(action, reason, opts \\ []) when is_list(opts) do
    details = Keyword.get(opts, :details, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_action(action),
         :ok <- validate_reason(reason),
         :ok <- validate_details(details),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         action: action,
         reason: reason,
         replacement: Keyword.get(opts, :replacement),
         details: details,
         metadata: metadata
       }}
    end
  end

  @spec new!(action(), atom() | String.t(), keyword()) :: t()
  def new!(action, reason, opts \\ []) do
    case new(action, reason, opts) do
      {:ok, guard_decision} -> guard_decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = guard_decision) do
    new(guard_decision.action, guard_decision.reason,
      replacement: guard_decision.replacement,
      details: guard_decision.details,
      metadata: guard_decision.metadata
    )
  end

  @spec allow(atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def allow(reason, opts \\ []), do: new(:allow, reason, opts)

  @spec allow!(atom() | String.t(), keyword()) :: t()
  def allow!(reason, opts \\ []), do: new!(:allow, reason, opts)

  @spec deny(atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def deny(reason, opts \\ []), do: new(:deny, reason, opts)

  @spec deny!(atom() | String.t(), keyword()) :: t()
  def deny!(reason, opts \\ []), do: new!(:deny, reason, opts)

  @spec review(atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def review(reason, opts \\ []), do: new(:review, reason, opts)

  @spec review!(atom() | String.t(), keyword()) :: t()
  def review!(reason, opts \\ []), do: new!(:review, reason, opts)

  @spec wait(atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def wait(reason, opts \\ []), do: new(:wait, reason, opts)

  @spec wait!(atom() | String.t(), keyword()) :: t()
  def wait!(reason, opts \\ []), do: new!(:wait, reason, opts)

  @spec rewrite(atom() | String.t(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def rewrite(reason, replacement, opts \\ []) do
    new(:rewrite, reason, Keyword.put(opts, :replacement, replacement))
  end

  @spec rewrite!(atom() | String.t(), term(), keyword()) :: t()
  def rewrite!(reason, replacement, opts \\ []) do
    new!(:rewrite, reason, Keyword.put(opts, :replacement, replacement))
  end

  defp validate_action(action) when action in @valid_actions, do: :ok

  defp validate_action(action) do
    {:error,
     Error.validation("invalid guard action: #{inspect(action)}",
       source: __MODULE__,
       details: %{action: action, valid_actions: @valid_actions}
     )}
  end

  defp validate_reason(reason) when is_atom(reason) or is_binary(reason), do: :ok

  defp validate_reason(reason) do
    {:error,
     Error.validation("guard reason must be an atom or string, got: #{inspect(reason)}",
       source: __MODULE__
     )}
  end

  defp validate_details(details) when is_map(details), do: :ok

  defp validate_details(details) do
    {:error,
     Error.validation("guard details must be a map, got: #{inspect(details)}", source: __MODULE__)}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("guard metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
