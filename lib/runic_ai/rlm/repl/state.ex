defmodule RunicAI.RLM.REPL.State do
  @moduledoc """
  Persistent state contract for an RLM-inspired sandbox REPL.

  The state stores handles, variables, bounded observations, checkpoints,
  budgets, and the structured final result. It deliberately stores only the
  model-visible sandbox session id, not the signed RunicSandbox session handle.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.REPL.EnvironmentFunction

  @runtimes [:python, :elixir, :node, :bash]

  @enforce_keys [
    :id,
    :sandbox_session_id,
    :runtime,
    :variables,
    :observations,
    :budgets,
    :environment_functions,
    :checkpoints,
    :metadata
  ]
  defstruct [
    :id,
    :sandbox_session_id,
    :runtime,
    :context_ref,
    :final_result,
    variables: %{},
    observations: [],
    budgets: %{},
    environment_functions: [],
    checkpoints: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          sandbox_session_id: String.t(),
          runtime: atom(),
          context_ref: term(),
          final_result: term(),
          variables: map(),
          observations: [map()],
          budgets: map(),
          environment_functions: [EnvironmentFunction.t()],
          checkpoints: [map()],
          metadata: map()
        }

  @spec runtimes() :: [atom()]
  def runtimes, do: @runtimes

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(sandbox_session_id, opts \\ [])
      when is_binary(sandbox_session_id) and is_list(opts) do
    id = Keyword.get(opts, :id) || "repl:#{System.unique_integer([:positive])}"
    runtime = Keyword.get(opts, :runtime, :python)
    variables = Keyword.get(opts, :variables, %{})
    observations = Keyword.get(opts, :observations, [])
    budgets = Keyword.get(opts, :budgets, %{})
    functions = Keyword.get(opts, :environment_functions, EnvironmentFunction.default_functions())
    checkpoints = Keyword.get(opts, :checkpoints, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_session_id(sandbox_session_id),
         {:ok, runtime} <- normalize_runtime(runtime),
         :ok <- validate_map(variables, :variables),
         :ok <- validate_observations(observations),
         :ok <- validate_budgets(budgets),
         {:ok, functions} <- normalize_functions(functions),
         :ok <- validate_checkpoints(checkpoints),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         sandbox_session_id: sandbox_session_id,
         runtime: runtime,
         context_ref: Keyword.get(opts, :context_ref),
         final_result: Keyword.get(opts, :final_result),
         variables: variables,
         observations: observations,
         budgets: budgets,
         environment_functions: functions,
         checkpoints: checkpoints,
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t(), keyword()) :: t()
  def new!(sandbox_session_id, opts \\ []) do
    case new(sandbox_session_id, opts) do
      {:ok, state} -> state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = state) do
    new(state.sandbox_session_id,
      id: state.id,
      runtime: state.runtime,
      context_ref: state.context_ref,
      final_result: state.final_result,
      variables: state.variables,
      observations: state.observations,
      budgets: state.budgets,
      environment_functions: state.environment_functions,
      checkpoints: state.checkpoints,
      metadata: state.metadata
    )
  end

  @spec put_variable(t(), String.t(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def put_variable(%__MODULE__{} = state, name, value, opts \\ [])
      when is_binary(name) and is_list(opts) do
    variable = %{
      value: value,
      kind: Keyword.get(opts, :kind, :value),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(%{state | variables: Map.put(state.variables, name, variable)})
  end

  @spec add_observation(t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def add_observation(%__MODULE__{} = state, observation) when is_map(observation) do
    observation =
      observation
      |> Map.put_new(:id, "observation:#{length(state.observations) + 1}")
      |> Map.put_new(:created_at, DateTime.utc_now())

    validate(%{state | observations: state.observations ++ [observation]})
  end

  @spec add_checkpoint(t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def add_checkpoint(%__MODULE__{} = state, checkpoint) when is_map(checkpoint) do
    validate(%{state | checkpoints: state.checkpoints ++ [checkpoint]})
  end

  @spec set_final(t(), term()) :: {:ok, t()} | {:error, Error.t()}
  def set_final(%__MODULE__{} = state, value), do: validate(%{state | final_result: value})

  @spec budget_status(t(), atom()) :: map()
  def budget_status(%__MODULE__{} = state, key) when is_atom(key) do
    state.budgets
    |> Map.get(key, Map.get(state.budgets, Atom.to_string(key), nil))
    |> normalize_budget_entry()
  end

  @spec consume_budget(t(), atom(), pos_integer()) :: {:ok, t()} | {:error, Error.t()}
  def consume_budget(%__MODULE__{} = state, key, count \\ 1)
      when is_atom(key) and is_integer(count) do
    status = budget_status(state, key)

    with :ok <- validate_positive_count(count, :count),
         :ok <- validate_budget_remaining(key, status, count) do
      entry =
        status
        |> Map.put(:used, status.used + count)
        |> Map.put(:remaining, remaining(status.limit, status.used + count))

      validate(%{state | budgets: Map.put(state.budgets, key, entry)})
    end
  end

  @spec validate_batch(t(), atom(), pos_integer()) :: :ok | {:error, Error.t()}
  def validate_batch(%__MODULE__{} = state, key, batch_size)
      when is_atom(key) and is_integer(batch_size) do
    status = budget_status(state, key)

    with :ok <- validate_positive_count(batch_size, :batch_size),
         :ok <- validate_batch_size(key, status, batch_size),
         :ok <- validate_budget_remaining(key, status, batch_size) do
      :ok
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("REPL state id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_session_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_session_id(id) do
    {:error,
     Error.validation("REPL state sandbox_session_id must be a non-empty string",
       source: __MODULE__,
       details: %{sandbox_session_id: id}
     )}
  end

  defp normalize_runtime(runtime) when runtime in @runtimes, do: {:ok, runtime}

  defp normalize_runtime(runtime) when is_binary(runtime) do
    Enum.find(@runtimes, &(Atom.to_string(&1) == runtime))
    |> case do
      nil -> invalid_runtime(runtime)
      runtime -> {:ok, runtime}
    end
  end

  defp normalize_runtime(runtime), do: invalid_runtime(runtime)

  defp invalid_runtime(runtime) do
    {:error,
     Error.validation("invalid REPL runtime",
       source: __MODULE__,
       details: %{runtime: runtime, valid_runtimes: @runtimes}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("REPL state #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_observations(observations) when is_list(observations), do: :ok

  defp validate_observations(observations) do
    {:error,
     Error.validation("REPL observations must be a list",
       source: __MODULE__,
       details: %{observations: observations}
     )}
  end

  defp validate_budgets(budgets) when is_map(budgets) do
    Enum.reduce_while(budgets, :ok, fn {key, value}, :ok ->
      case validate_budget_entry(key, value) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_budgets(budgets) do
    {:error,
     Error.validation("REPL state budgets must be a map",
       source: __MODULE__,
       details: %{field: :budgets, value: budgets}
     )}
  end

  defp validate_budget_entry(_key, limit) when is_integer(limit) and limit >= 0, do: :ok

  defp validate_budget_entry(key, entry) when is_map(entry) do
    limit = get_budget(entry, :limit)
    used = get_budget(entry, :used) || 0
    max_batch_size = get_budget(entry, :max_batch_size)

    with :ok <- validate_optional_non_negative_integer(key, :limit, limit),
         :ok <- validate_non_negative_integer(key, :used, used),
         :ok <- validate_optional_positive_integer(key, :max_batch_size, max_batch_size),
         :ok <- validate_used_within_limit(key, limit, used) do
      :ok
    end
  end

  defp validate_budget_entry(key, value) do
    {:error,
     Error.validation("REPL budget entry must be a non-negative integer or map",
       source: __MODULE__,
       details: %{budget_key: key, value: value}
     )}
  end

  defp normalize_functions(functions) when is_list(functions) do
    functions
    |> Enum.reduce_while({:ok, []}, fn function, {:ok, acc} ->
      case normalize_function(function) do
        {:ok, function} -> {:cont, {:ok, [function | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, functions} -> {:ok, Enum.reverse(functions)}
      error -> error
    end
  end

  defp normalize_functions(functions) do
    {:error,
     Error.validation("REPL environment_functions must be a list",
       source: __MODULE__,
       details: %{environment_functions: functions}
     )}
  end

  defp normalize_function(%EnvironmentFunction{} = function),
    do: EnvironmentFunction.validate(function)

  defp normalize_function(function) when is_map(function) or is_list(function),
    do: EnvironmentFunction.new(function)

  defp normalize_function(function) do
    {:error,
     Error.validation("REPL environment function must be a descriptor",
       source: __MODULE__,
       details: %{environment_function: function}
     )}
  end

  defp validate_checkpoints(checkpoints) when is_list(checkpoints), do: :ok

  defp validate_checkpoints(checkpoints) do
    {:error,
     Error.validation("REPL checkpoints must be a list",
       source: __MODULE__,
       details: %{checkpoints: checkpoints}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("REPL state metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp normalize_budget_entry(nil),
    do: %{limit: nil, used: 0, remaining: nil, max_batch_size: nil}

  defp normalize_budget_entry(limit) when is_integer(limit) and limit >= 0 do
    %{limit: limit, used: 0, remaining: limit, max_batch_size: nil}
  end

  defp normalize_budget_entry(entry) when is_map(entry) do
    limit = get_budget(entry, :limit)
    used = get_budget(entry, :used) || 0
    max_batch_size = get_budget(entry, :max_batch_size)

    %{
      limit: limit,
      used: used,
      remaining: remaining(limit, used),
      max_batch_size: max_batch_size
    }
  end

  defp normalize_budget_entry(_entry),
    do: %{limit: nil, used: 0, remaining: nil, max_batch_size: nil}

  defp validate_optional_non_negative_integer(_key, _field, nil), do: :ok

  defp validate_optional_non_negative_integer(key, field, value),
    do: validate_non_negative_integer(key, field, value)

  defp validate_non_negative_integer(_key, _field, value) when is_integer(value) and value >= 0,
    do: :ok

  defp validate_non_negative_integer(key, field, value) do
    {:error,
     Error.validation("REPL budget #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{budget_key: key, field: field, value: value}
     )}
  end

  defp validate_optional_positive_integer(_key, _field, nil), do: :ok

  defp validate_optional_positive_integer(_key, _field, value)
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_optional_positive_integer(key, field, value) do
    {:error,
     Error.validation("REPL budget #{field} must be a positive integer or nil",
       source: __MODULE__,
       details: %{budget_key: key, field: field, value: value}
     )}
  end

  defp validate_used_within_limit(_key, nil, _used), do: :ok

  defp validate_used_within_limit(key, limit, used) do
    if used <= limit do
      :ok
    else
      {:error,
       Error.validation("REPL budget used count exceeds limit",
         source: __MODULE__,
         details: %{budget_key: key, limit: limit, used: used}
       )}
    end
  end

  defp validate_positive_count(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_count(value, field) do
    {:error,
     Error.validation("REPL budget #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_budget_remaining(_key, %{limit: nil}, _count), do: :ok

  defp validate_budget_remaining(key, status, count) do
    if status.used + count <= status.limit do
      :ok
    else
      {:error,
       Error.validation("REPL budget exceeded",
         source: __MODULE__,
         details: %{budget_key: key, limit: status.limit, used: status.used, requested: count}
       )}
    end
  end

  defp validate_batch_size(_key, %{max_batch_size: nil}, _batch_size), do: :ok

  defp validate_batch_size(key, status, batch_size) do
    if batch_size <= status.max_batch_size do
      :ok
    else
      {:error,
       Error.validation("REPL batch size exceeded",
         source: __MODULE__,
         details: %{
           budget_key: key,
           max_batch_size: status.max_batch_size,
           batch_size: batch_size
         }
       )}
    end
  end

  defp remaining(nil, _used), do: nil
  defp remaining(limit, used) when is_integer(limit), do: max(limit - used, 0)

  defp get_budget(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
