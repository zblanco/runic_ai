defmodule RunicAI.Harness.Policy do
  @moduledoc """
  Process-agnostic execution policy for harness-managed sessions.
  """

  alias RunicAI.Error
  alias RunicAI.Trace.CapturePolicy
  alias RunicAI.Trace.Sink

  @default_stop_on [:review, :wait, :error]

  @enforce_keys [:stop_on, :capture_policy, :run_context, :metadata]
  defstruct max_reactions: 16,
            max_turns: nil,
            max_wall_time_ms: nil,
            stop_on: @default_stop_on,
            capture_policy: nil,
            sinks: [],
            run_context: %{},
            async: false,
            metadata: %{}

  @type t :: %__MODULE__{
          max_reactions: pos_integer(),
          max_turns: pos_integer() | nil,
          max_wall_time_ms: pos_integer() | nil,
          stop_on: [atom()],
          capture_policy: CapturePolicy.t(),
          sinks: [Sink.normalized_sink()],
          run_context: map(),
          async: boolean(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    run_context = Keyword.get(opts, :run_context, %{})

    with :ok <- validate_positive_integer(Keyword.get(opts, :max_reactions, 16), :max_reactions),
         :ok <- validate_optional_positive_integer(Keyword.get(opts, :max_turns), :max_turns),
         :ok <-
           validate_optional_positive_integer(
             Keyword.get(opts, :max_wall_time_ms),
             :max_wall_time_ms
           ),
         {:ok, stop_on} <- normalize_stop_on(Keyword.get(opts, :stop_on, @default_stop_on)),
         {:ok, capture_policy} <- CapturePolicy.from_input(Keyword.get(opts, :capture_policy)),
         {:ok, sinks} <- Sink.normalize_input(Keyword.get(opts, :sinks, [])),
         :ok <- validate_map(run_context, :run_context),
         :ok <- validate_boolean(Keyword.get(opts, :async, false), :async),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         max_reactions: Keyword.get(opts, :max_reactions, 16),
         max_turns: Keyword.get(opts, :max_turns),
         max_wall_time_ms: Keyword.get(opts, :max_wall_time_ms),
         stop_on: stop_on,
         capture_policy: capture_policy,
         sinks: sinks,
         run_context: run_context,
         async: Keyword.get(opts, :async, false),
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

  @spec from_input(t() | keyword() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: validate(policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(other) do
    {:error,
     Error.validation("expected a Harness.Policy-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec from_input!(t() | keyword() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      max_reactions: policy.max_reactions,
      max_turns: policy.max_turns,
      max_wall_time_ms: policy.max_wall_time_ms,
      stop_on: policy.stop_on,
      capture_policy: policy.capture_policy,
      sinks: policy.sinks,
      run_context: policy.run_context,
      async: policy.async,
      metadata: policy.metadata
    )
  end

  @spec stop_on?(t(), atom()) :: boolean()
  def stop_on?(%__MODULE__{stop_on: stop_on}, signal) when is_atom(signal), do: signal in stop_on

  defp normalize_stop_on(stop_on) when is_list(stop_on) do
    stop_on
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_atom(value) ->
        {:cont, {:ok, [value | acc]}}

      value, {:ok, acc} when is_binary(value) and value != "" ->
        {:cont, {:ok, [String.to_atom(value) | acc]}}

      value, _acc ->
        {:halt,
         {:error,
          Error.validation("harness policy stop_on entries must be atoms or strings",
            source: __MODULE__,
            details: %{entry: value}
          )}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp normalize_stop_on(other) do
    {:error,
     Error.validation("harness policy stop_on must be a list",
       source: __MODULE__,
       details: %{stop_on: other}
     )}
  end

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(value, field) do
    {:error,
     Error.validation("harness policy #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_positive_integer(nil, _field), do: :ok

  defp validate_optional_positive_integer(value, field),
    do: validate_positive_integer(value, field)

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("harness policy #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("harness policy #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
