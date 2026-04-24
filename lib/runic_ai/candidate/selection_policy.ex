defmodule RunicAI.Candidate.SelectionPolicy do
  @moduledoc """
  Deterministic candidate selection policy.
  """

  alias RunicAI.Candidate.Assignment
  alias RunicAI.Candidate.Registry
  alias RunicAI.Error

  @valid_strategies [:first, :explicit, :hash]

  @enforce_keys [:strategy, :metadata]
  defstruct strategy: :first, candidate_id: nil, metadata: %{}

  @type t :: %__MODULE__{
          strategy: :first | :explicit | :hash,
          candidate_id: String.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    strategy = Keyword.get(opts, :strategy, :first)
    candidate_id = Keyword.get(opts, :candidate_id)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_strategy(strategy),
         :ok <- validate_candidate_id(strategy, candidate_id),
         :ok <- validate_map(metadata, :metadata) do
      {:ok, %__MODULE__{strategy: strategy, candidate_id: candidate_id, metadata: metadata}}
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

  def from_input(%__MODULE__{} = policy),
    do:
      new(strategy: policy.strategy, candidate_id: policy.candidate_id, metadata: policy.metadata)

  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(other) do
    {:error,
     Error.validation("expected a Candidate.SelectionPolicy-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec select(t(), Registry.t(), keyword()) :: {:ok, Assignment.t()} | {:error, Error.t()}
  def select(
        %__MODULE__{strategy: :explicit, candidate_id: candidate_id},
        %Registry{} = registry,
        opts
      ) do
    with {:ok, candidate} <- Registry.fetch(registry, candidate_id) do
      Assignment.new(candidate.id, candidate,
        reason: :explicit,
        metadata: assignment_metadata(opts)
      )
    end
  end

  def select(%__MODULE__{strategy: :first}, %Registry{} = registry, opts) do
    registry
    |> Registry.list()
    |> Enum.sort_by(& &1.id)
    |> case do
      [candidate | _rest] ->
        Assignment.new(candidate.id, candidate,
          reason: :first,
          metadata: assignment_metadata(opts)
        )

      [] ->
        {:error, Error.validation("candidate registry is empty", source: __MODULE__)}
    end
  end

  def select(%__MODULE__{strategy: :hash}, %Registry{} = registry, opts) do
    candidates = registry |> Registry.list() |> Enum.sort_by(& &1.id)

    case candidates do
      [] ->
        {:error, Error.validation("candidate registry is empty", source: __MODULE__)}

      [_ | _] ->
        index =
          opts
          |> Keyword.get(:session_id, inspect(Keyword.get(opts, :input)))
          |> :erlang.phash2(length(candidates))

        candidate = Enum.at(candidates, index)

        Assignment.new(candidate.id, candidate,
          reason: :hash,
          metadata: assignment_metadata(opts)
        )
    end
  end

  defp validate_strategy(strategy) when strategy in @valid_strategies, do: :ok

  defp validate_strategy(strategy) do
    {:error,
     Error.validation("invalid candidate selection strategy",
       source: __MODULE__,
       details: %{strategy: strategy, valid_strategies: @valid_strategies}
     )}
  end

  defp validate_candidate_id(:explicit, candidate_id)
       when is_binary(candidate_id) and candidate_id != "",
       do: :ok

  defp validate_candidate_id(:explicit, candidate_id) do
    {:error,
     Error.validation("explicit candidate selection requires a candidate_id",
       source: __MODULE__,
       details: %{candidate_id: candidate_id}
     )}
  end

  defp validate_candidate_id(_strategy, nil), do: :ok
  defp validate_candidate_id(_strategy, candidate_id) when is_binary(candidate_id), do: :ok

  defp validate_candidate_id(_strategy, candidate_id) do
    {:error,
     Error.validation("candidate_id must be a string or nil",
       source: __MODULE__,
       details: %{candidate_id: candidate_id}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("candidate selection #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp assignment_metadata(opts) do
    %{
      session_id: Keyword.get(opts, :session_id),
      input: Keyword.get(opts, :input)
    }
  end
end
