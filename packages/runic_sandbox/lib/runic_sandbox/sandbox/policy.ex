defmodule RunicSandbox.Policy do
  @moduledoc """
  Execution policy for a sandbox profile or one execution request.
  """

  alias RunicSandbox.Error

  @valid_network [:disabled, :host, :restricted]
  @valid_isolation_levels [
    :in_process,
    :in_process_virtual,
    :wasi,
    :namespace,
    :container,
    :gvisor,
    :microvm,
    :remote_microvm
  ]

  @enforce_keys [
    :network,
    :timeout_ms,
    :max_output_bytes,
    :allowed_runtimes,
    :isolation_minimum,
    :persist_changes?,
    :metadata
  ]
  defstruct network: :disabled,
            timeout_ms: 30_000,
            max_output_bytes: 65_536,
            allowed_runtimes: [],
            isolation_minimum: :in_process,
            persist_changes?: false,
            metadata: %{}

  @type network :: :disabled | :host | :restricted
  @type isolation_level ::
          :in_process
          | :in_process_virtual
          | :wasi
          | :namespace
          | :container
          | :gvisor
          | :microvm
          | :remote_microvm

  @type t :: %__MODULE__{
          network: network(),
          timeout_ms: pos_integer() | :infinity,
          max_output_bytes: pos_integer(),
          allowed_runtimes: [atom()],
          isolation_minimum: isolation_level(),
          persist_changes?: boolean(),
          metadata: map()
        }

  @spec isolation_levels() :: [isolation_level()]
  def isolation_levels, do: @valid_isolation_levels

  @spec new(keyword() | map() | t() | nil) :: {:ok, t()} | {:error, Error.t()}
  def new(nil), do: new([])
  def new(%__MODULE__{} = policy), do: validate(policy)

  def new(input) when is_map(input) do
    new(
      network: get(input, :network, :disabled),
      timeout_ms: get(input, :timeout_ms, 30_000),
      max_output_bytes: get(input, :max_output_bytes, 65_536),
      allowed_runtimes: get(input, :allowed_runtimes, []),
      isolation_minimum: get(input, :isolation_minimum, :in_process),
      persist_changes?: get(input, :persist_changes?, false),
      metadata: get(input, :metadata, %{})
    )
  end

  def new(opts) when is_list(opts) do
    network = normalize_network(Keyword.get(opts, :network, :disabled))
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, 65_536)
    allowed_runtimes = Keyword.get(opts, :allowed_runtimes, [])
    isolation_minimum = normalize_isolation(Keyword.get(opts, :isolation_minimum, :in_process))
    persist_changes? = Keyword.get(opts, :persist_changes?, false)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_network(network),
         :ok <- validate_timeout(timeout_ms),
         :ok <- validate_positive_integer(max_output_bytes, :max_output_bytes),
         {:ok, allowed_runtimes} <- normalize_atom_list(allowed_runtimes, :allowed_runtimes),
         :ok <- validate_isolation(isolation_minimum),
         :ok <- validate_boolean(persist_changes?, :persist_changes?),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         network: network,
         timeout_ms: timeout_ms,
         max_output_bytes: max_output_bytes,
         allowed_runtimes: allowed_runtimes,
         isolation_minimum: isolation_minimum,
         persist_changes?: persist_changes?,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map() | t() | nil) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      network: policy.network,
      timeout_ms: policy.timeout_ms,
      max_output_bytes: policy.max_output_bytes,
      allowed_runtimes: policy.allowed_runtimes,
      isolation_minimum: policy.isolation_minimum,
      persist_changes?: policy.persist_changes?,
      metadata: policy.metadata
    )
  end

  defp normalize_network(value) when value in @valid_network, do: value
  defp normalize_network("disabled"), do: :disabled
  defp normalize_network("host"), do: :host
  defp normalize_network("restricted"), do: :restricted
  defp normalize_network(%{enabled: false}), do: :disabled
  defp normalize_network(%{"enabled" => false}), do: :disabled
  defp normalize_network(%{enabled: true}), do: :host
  defp normalize_network(%{"enabled" => true}), do: :host
  defp normalize_network(value), do: value

  defp normalize_isolation(value) when value in @valid_isolation_levels, do: value

  defp normalize_isolation(value) when is_binary(value) and value != "" do
    Enum.find(@valid_isolation_levels, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_isolation(value), do: value

  defp validate_network(network) when network in @valid_network, do: :ok

  defp validate_network(network) do
    {:error,
     Error.validation("invalid sandbox network policy",
       source: __MODULE__,
       details: %{network: network, valid_network: @valid_network}
     )}
  end

  defp validate_isolation(level) when level in @valid_isolation_levels, do: :ok

  defp validate_isolation(level) do
    {:error,
     Error.validation("invalid sandbox isolation level",
       source: __MODULE__,
       details: %{isolation_level: level, valid_isolation_levels: @valid_isolation_levels}
     )}
  end

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(value), do: validate_positive_integer(value, :timeout_ms)

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(value, field) do
    {:error,
     Error.validation("sandbox #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_atom_list(values, field) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_atom(value) do
        {:ok, atom} ->
          {:cont, {:ok, [atom | acc]}}

        {:error, error} ->
          {:halt, {:error, %{error | details: Map.put(error.details, :field, field)}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_atom_list(value, field) do
    {:error,
     Error.validation("sandbox #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_atom(value) when is_atom(value), do: {:ok, value}

  defp normalize_atom(value) when is_binary(value) and value != "" do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError ->
      {:error,
       Error.validation("sandbox value must be a known atom string",
         source: __MODULE__,
         details: %{value: value}
       )}
  end

  defp normalize_atom(value) do
    {:error,
     Error.validation("sandbox value must be an atom or non-empty string",
       source: __MODULE__,
       details: %{value: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("sandbox #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
