defmodule RunicAI.Decomposition.JoinPolicy do
  @moduledoc """
  Declarative policy describing how child results are reduced.
  """

  alias RunicAI.Decomposition.Callable
  alias RunicAI.Error

  @valid_modes [:all, :all_settled, :first_success, :quorum, :score, :merge, :custom]
  @valid_partial_failure [:fail, :ignore, :review, :halt]
  @valid_merge_conflicts [:error, :first_wins, :last_wins, :nest_by_task]

  @enforce_keys [:mode, :quorum, :on_partial_failure, :metadata]
  defstruct [
    :mode,
    :quorum,
    :score_by,
    :merge_conflicts,
    :on_partial_failure,
    :synthesizer,
    :metadata
  ]

  @type mode :: :all | :all_settled | :first_success | :quorum | :score | :merge | :custom
  @type merge_conflicts :: :error | :first_wins | :last_wins | :nest_by_task

  @type t :: %__MODULE__{
          mode: mode(),
          quorum: pos_integer(),
          score_by: atom() | String.t() | Callable.t() | nil,
          merge_conflicts: merge_conflicts(),
          on_partial_failure: :fail | :ignore | :review | :halt,
          synthesizer: Callable.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :all)
    quorum = Keyword.get(opts, :quorum, 1)
    score_by = Keyword.get(opts, :score_by)
    merge_conflicts = Keyword.get(opts, :merge_conflicts, :error)
    on_partial_failure = Keyword.get(opts, :on_partial_failure, :fail)
    synthesizer = Keyword.get(opts, :synthesizer)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_mode(mode),
         :ok <- validate_quorum(quorum),
         :ok <- validate_score_by(score_by),
         :ok <- validate_merge_conflicts(merge_conflicts),
         :ok <- validate_on_partial_failure(on_partial_failure),
         :ok <- validate_synthesizer(mode, synthesizer),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         mode: mode,
         quorum: quorum,
         score_by: score_by,
         merge_conflicts: merge_conflicts,
         on_partial_failure: on_partial_failure,
         synthesizer: synthesizer,
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

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      mode: policy.mode,
      quorum: policy.quorum,
      score_by: policy.score_by,
      merge_conflicts: policy.merge_conflicts,
      on_partial_failure: policy.on_partial_failure,
      synthesizer: policy.synthesizer,
      metadata: policy.metadata
    )
  end

  @spec from_input(t() | keyword() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: validate(policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(other) do
    {:error,
     Error.validation("expected a JoinPolicy-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | keyword() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_mode(mode) when mode in @valid_modes, do: :ok

  defp validate_mode(mode) do
    {:error,
     Error.validation("invalid decomposition join mode: #{inspect(mode)}",
       source: __MODULE__,
       details: %{mode: mode, valid_modes: @valid_modes}
     )}
  end

  defp validate_quorum(quorum) when is_integer(quorum) and quorum > 0, do: :ok

  defp validate_quorum(quorum) do
    {:error,
     Error.validation("decomposition join quorum must be a positive integer",
       source: __MODULE__,
       details: %{quorum: quorum}
     )}
  end

  defp validate_score_by(nil), do: :ok
  defp validate_score_by(score_by) when is_atom(score_by) or is_binary(score_by), do: :ok

  defp validate_score_by(score_by) do
    Callable.validate(score_by, "decomposition join score_by", __MODULE__)
  end

  defp validate_merge_conflicts(mode) when mode in @valid_merge_conflicts, do: :ok

  defp validate_merge_conflicts(mode) do
    {:error,
     Error.validation("invalid decomposition merge_conflicts policy: #{inspect(mode)}",
       source: __MODULE__,
       details: %{merge_conflicts: mode, valid_values: @valid_merge_conflicts}
     )}
  end

  defp validate_on_partial_failure(mode) when mode in @valid_partial_failure, do: :ok

  defp validate_on_partial_failure(mode) do
    {:error,
     Error.validation("invalid decomposition on_partial_failure policy: #{inspect(mode)}",
       source: __MODULE__,
       details: %{on_partial_failure: mode, valid_values: @valid_partial_failure}
     )}
  end

  defp validate_synthesizer(:custom, nil) do
    {:error,
     Error.validation("custom decomposition join mode requires a synthesizer callback",
       source: __MODULE__
     )}
  end

  defp validate_synthesizer(_mode, nil), do: :ok

  defp validate_synthesizer(_mode, synthesizer) do
    Callable.validate(synthesizer, "decomposition join synthesizer", __MODULE__)
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("decomposition join metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
