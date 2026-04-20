defmodule RunicAI.Tool.ExecutionPlan do
  @moduledoc """
  Executable plan for one requested tool batch.
  """

  alias RunicAI.Error
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.ExecutionPolicy

  @enforce_keys [:calls, :policy, :metadata]
  defstruct [:calls, :policy, :groups, :metadata]

  @type t :: %__MODULE__{
          calls: [CallRequest.t()],
          policy: ExecutionPolicy.t(),
          groups: [[String.t() | CallRequest.t()]] | nil,
          metadata: map()
        }

  @spec new([CallRequest.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(calls \\ [], opts \\ []) when is_list(calls) and is_list(opts) do
    groups = Keyword.get(opts, :groups)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_calls} <- normalize_calls(calls),
         {:ok, policy} <- ExecutionPolicy.from_input(Keyword.get(opts, :policy)),
         :ok <- validate_groups(groups),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         calls: normalized_calls,
         policy: policy,
         groups: groups,
         metadata: metadata
       }}
    end
  end

  @spec new!([CallRequest.t()], keyword()) :: t()
  def new!(calls \\ [], opts \\ []) do
    case new(calls, opts) do
      {:ok, plan} -> plan
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = plan) do
    new(plan.calls, policy: plan.policy, groups: plan.groups, metadata: plan.metadata)
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{calls: []}), do: true
  def empty?(%__MODULE__{}), do: false

  defp normalize_calls(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, acc} ->
      case CallRequest.validate(call) do
        {:ok, normalized_call} -> {:cont, {:ok, [normalized_call | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_calls} -> {:ok, Enum.reverse(normalized_calls)}
      error -> error
    end
  end

  defp validate_groups(nil), do: :ok

  defp validate_groups(groups) when is_list(groups) do
    if Enum.all?(groups, &is_list/1) do
      :ok
    else
      {:error,
       Error.validation("tool execution groups must be a list of lists", source: __MODULE__)}
    end
  end

  defp validate_groups(groups) do
    {:error,
     Error.validation("tool execution groups must be nil or a list, got: #{inspect(groups)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool execution plan metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
