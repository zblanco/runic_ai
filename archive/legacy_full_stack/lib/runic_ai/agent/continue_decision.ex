defmodule RunicAI.Agent.ContinueDecision do
  @moduledoc """
  Explicit control decision for whether the conversational kernel continues.
  """

  alias RunicAI.Error

  @valid_actions [:continue, :stop, :halt]

  @enforce_keys [:action, :reason]
  defstruct [:action, :reason, metadata: %{}]

  @type action :: :continue | :stop | :halt

  @type t :: %__MODULE__{
          action: action(),
          reason: atom() | String.t(),
          metadata: map()
        }

  @spec new(action(), atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(action, reason, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_action(action),
         :ok <- validate_reason(reason),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{action: action, reason: reason, metadata: metadata}}
    end
  end

  @spec new!(action(), atom() | String.t(), keyword()) :: t()
  def new!(action, reason, opts \\ []) do
    case new(action, reason, opts) do
      {:ok, decision} -> decision
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = decision) do
    new(decision.action, decision.reason, metadata: decision.metadata)
  end

  @spec continue(atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def continue(reason, opts \\ []), do: new(:continue, reason, opts)

  @spec continue!(atom() | String.t(), keyword()) :: t()
  def continue!(reason, opts \\ []), do: new!(:continue, reason, opts)

  @spec stop(atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def stop(reason, opts \\ []), do: new(:stop, reason, opts)

  @spec stop!(atom() | String.t(), keyword()) :: t()
  def stop!(reason, opts \\ []), do: new!(:stop, reason, opts)

  @spec halt(atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def halt(reason, opts \\ []), do: new(:halt, reason, opts)

  @spec halt!(atom() | String.t(), keyword()) :: t()
  def halt!(reason, opts \\ []), do: new!(:halt, reason, opts)

  @spec from_value(t() | :continue | :stop | :halt | boolean(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def from_value(%__MODULE__{} = decision, _opts), do: validate(decision)
  def from_value(:continue, opts), do: continue(Keyword.get(opts, :reason, :continue), opts)
  def from_value(:stop, opts), do: stop(Keyword.get(opts, :reason, :stop), opts)
  def from_value(:halt, opts), do: halt(Keyword.get(opts, :reason, :halt), opts)
  def from_value(true, opts), do: continue(Keyword.get(opts, :reason, :continue), opts)
  def from_value(false, opts), do: stop(Keyword.get(opts, :reason, :stop), opts)

  def from_value(other, _opts) do
    {:error,
     Error.validation("unsupported continuation decision value: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp validate_action(action) when action in @valid_actions, do: :ok

  defp validate_action(action) do
    {:error,
     Error.validation("invalid continue decision action: #{inspect(action)}",
       source: __MODULE__,
       details: %{action: action, valid_actions: @valid_actions}
     )}
  end

  defp validate_reason(reason) when is_atom(reason) or is_binary(reason), do: :ok

  defp validate_reason(reason) do
    {:error,
     Error.validation(
       "continue decision reason must be an atom or string, got: #{inspect(reason)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("continue decision metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
