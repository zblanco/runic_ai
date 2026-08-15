defmodule RunicAI.Control.RetryPolicy do
  @moduledoc "Portable retry decisions constrained by error and replay semantics."

  alias RunicAI.Error
  alias RunicAI.JSONValue

  @wire_id "runic.ai/retry-policy/v1"
  @kinds ~w(validation provider timeout unavailable denied conflict internal)

  defstruct max_attempts: 1,
            base_delay_ms: 0,
            max_delay_ms: 30_000,
            multiplier: 2,
            retryable_kinds: ["provider", "timeout", "unavailable"],
            retryable_codes: []

  @type t :: %__MODULE__{}

  def new(input \\ %{}) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input) do
      validate(%__MODULE__{
        max_attempts: Map.get(map, "max_attempts", 1),
        base_delay_ms: Map.get(map, "base_delay_ms", 0),
        max_delay_ms: Map.get(map, "max_delay_ms", 30_000),
        multiplier: Map.get(map, "multiplier", 2),
        retryable_kinds: Map.get(map, "retryable_kinds", ["provider", "timeout", "unavailable"]),
        retryable_codes: Map.get(map, "retryable_codes", [])
      })
    else
      {:ok, _other} -> error([], "retry policy must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def new!(input \\ %{}) do
    case new(input) do
      {:ok, policy} -> policy
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def decide(%__MODULE__{} = policy, %Error{} = error, attempt, opts \\ [])
      when is_integer(attempt) and attempt > 0 do
    replay = Keyword.get(opts, :replay, :pure)
    idempotency = Keyword.get(opts, :idempotency)

    cond do
      attempt >= policy.max_attempts -> {:stop, :attempts_exhausted}
      replay == :unsafe and not is_binary(idempotency) -> {:stop, :unsafe_replay}
      not retryable?(policy, error) -> {:stop, :not_retryable}
      true -> {:retry, delay_ms(policy, attempt)}
    end
  end

  def delay_ms(%__MODULE__{} = policy, attempt) when is_integer(attempt) and attempt > 0,
    do:
      min(
        round(policy.base_delay_ms * :math.pow(policy.multiplier, attempt - 1)),
        policy.max_delay_ms
      )

  def encode(%__MODULE__{} = policy),
    do: %{
      "$contract" => @wire_id,
      "max_attempts" => policy.max_attempts,
      "base_delay_ms" => policy.base_delay_ms,
      "max_delay_ms" => policy.max_delay_ms,
      "multiplier" => policy.multiplier,
      "retryable_kinds" => policy.retryable_kinds,
      "retryable_codes" => policy.retryable_codes
    }

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract") == @wire_id do
      new(map)
    else
      false -> error(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> error([], "retry policy must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  defp retryable?(policy, error),
    do:
      error.retryable or Atom.to_string(error.kind) in policy.retryable_kinds or
        error.code in policy.retryable_codes

  defp validate(policy) do
    issues =
      []
      |> check(positive?(policy.max_attempts), ["max_attempts"], "must be positive")
      |> check(non_negative?(policy.base_delay_ms), ["base_delay_ms"], "must be non-negative")
      |> check(non_negative?(policy.max_delay_ms), ["max_delay_ms"], "must be non-negative")
      |> check(
        policy.max_delay_ms >= policy.base_delay_ms,
        ["max_delay_ms"],
        "must cover base delay"
      )
      |> check(
        is_number(policy.multiplier) and policy.multiplier >= 1,
        ["multiplier"],
        "must be at least one"
      )
      |> check(
        enum_list?(policy.retryable_kinds),
        ["retryable_kinds"],
        "contains an unsupported kind"
      )
      |> check(
        string_list?(policy.retryable_codes),
        ["retryable_codes"],
        "must be a list of strings"
      )
      |> Enum.reverse()

    if issues == [], do: {:ok, policy}, else: {:error, issues}
  end

  defp positive?(value), do: is_integer(value) and value > 0
  defp non_negative?(value), do: is_integer(value) and value >= 0
  defp enum_list?(value), do: string_list?(value) and Enum.all?(value, &(&1 in @kinds))
  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp check(issues, true, _path, _message), do: issues
  defp check(issues, false, path, message), do: [%{path: path, message: message} | issues]
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
