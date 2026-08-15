defmodule RunicAI.Tool.ExecutionPolicy do
  @moduledoc """
  Workflow-visible execution constraints for one tool or tool batch.
  """

  alias RunicAI.Error

  @valid_modes [:parallel, :serial]
  @valid_stop_on_error [false, true, :stop, :halt]

  @enforce_keys [:mode, :timeout, :dispatch, :stop_on_error, :metadata]
  defstruct [
    :mode,
    :timeout,
    :max_concurrency,
    :retry,
    :dispatch,
    :stop_on_error,
    :metadata
  ]

  @type mode :: :parallel | :serial | {:staged, [[String.t() | term()]]}

  @type t :: %__MODULE__{
          mode: mode(),
          timeout: non_neg_integer() | :infinity | nil,
          max_concurrency: pos_integer() | nil,
          retry: term(),
          dispatch: term(),
          stop_on_error: false | true | :stop | :halt,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :parallel)
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_concurrency = Keyword.get(opts, :max_concurrency)
    retry = Keyword.get(opts, :retry)
    dispatch = Keyword.get(opts, :dispatch, :immediate)
    stop_on_error = Keyword.get(opts, :stop_on_error, false)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_mode(mode),
         :ok <- validate_timeout(timeout),
         :ok <- validate_max_concurrency(max_concurrency),
         :ok <- validate_stop_on_error(stop_on_error),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         mode: mode,
         timeout: timeout,
         max_concurrency: max_concurrency,
         retry: retry,
         dispatch: dispatch,
         stop_on_error: stop_on_error,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: validate(policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      mode: Map.get(input, :mode, :parallel),
      timeout: Map.get(input, :timeout, 30_000),
      max_concurrency: Map.get(input, :max_concurrency),
      retry: Map.get(input, :retry),
      dispatch: Map.get(input, :dispatch, :immediate),
      stop_on_error: Map.get(input, :stop_on_error, false),
      metadata: Map.get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Tool.ExecutionPolicy-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | keyword() | map() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      mode: policy.mode,
      timeout: policy.timeout,
      max_concurrency: policy.max_concurrency,
      retry: policy.retry,
      dispatch: policy.dispatch,
      stop_on_error: policy.stop_on_error,
      metadata: policy.metadata
    )
  end

  @spec effective_max_concurrency(t()) :: pos_integer()
  def effective_max_concurrency(%__MODULE__{max_concurrency: nil}) do
    System.schedulers_online()
  end

  def effective_max_concurrency(%__MODULE__{max_concurrency: max_concurrency}),
    do: max_concurrency

  @spec halt_action(t()) :: :continue | :stop | :halt
  def halt_action(%__MODULE__{stop_on_error: false}), do: :continue
  def halt_action(%__MODULE__{stop_on_error: true}), do: :halt
  def halt_action(%__MODULE__{stop_on_error: :halt}), do: :halt
  def halt_action(%__MODULE__{stop_on_error: :stop}), do: :stop

  defp validate_mode(mode) when mode in @valid_modes, do: :ok
  defp validate_mode({:staged, groups}) when is_list(groups), do: :ok

  defp validate_mode(mode) do
    {:error,
     Error.validation("invalid tool execution mode: #{inspect(mode)}",
       source: __MODULE__,
       details: %{mode: mode, valid_modes: @valid_modes ++ [{:staged, :groups}]}
     )}
  end

  defp validate_timeout(nil), do: :ok
  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok

  defp validate_timeout(timeout) do
    {:error,
     Error.validation("tool execution timeout must be nil, :infinity, or non-negative integer",
       source: __MODULE__,
       details: %{timeout: timeout}
     )}
  end

  defp validate_max_concurrency(nil), do: :ok
  defp validate_max_concurrency(max) when is_integer(max) and max > 0, do: :ok

  defp validate_max_concurrency(max_concurrency) do
    {:error,
     Error.validation("tool max_concurrency must be a positive integer or nil",
       source: __MODULE__,
       details: %{max_concurrency: max_concurrency}
     )}
  end

  defp validate_stop_on_error(stop_on_error) when stop_on_error in @valid_stop_on_error, do: :ok

  defp validate_stop_on_error(stop_on_error) do
    {:error,
     Error.validation("invalid stop_on_error value: #{inspect(stop_on_error)}",
       source: __MODULE__,
       details: %{stop_on_error: stop_on_error, valid_values: @valid_stop_on_error}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool execution policy metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
