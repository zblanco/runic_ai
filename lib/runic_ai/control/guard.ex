defmodule RunicAI.Control.Guard do
  @moduledoc "Serializable outcome of a host-owned policy decision."

  alias RunicAI.Error
  alias RunicAI.JSONValue

  @wire_id "runic.ai/guard-decision/v1"
  @decisions [:allow, :deny, :review]

  @enforce_keys [:id, :decision, :reason]
  defstruct id: nil, decision: nil, reason: nil, policies: [], metadata: %{}

  @type t :: %__MODULE__{}

  def new(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         {:ok, decision} <- decision(Map.get(map, "decision")),
         true <- identifier?(Map.get(map, "id")),
         true <- non_empty?(Map.get(map, "reason")),
         true <- string_list?(Map.get(map, "policies", [])),
         metadata when is_map(metadata) <- Map.get(map, "metadata", %{}) do
      {:ok,
       %__MODULE__{
         id: Map.get(map, "id"),
         decision: decision,
         reason: Map.get(map, "reason"),
         policies: Map.get(map, "policies", []),
         metadata: metadata
       }}
    else
      false -> error([], "guard fields are invalid")
      {:ok, _other} -> error([], "guard decision must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def new!(input) do
    case new(input) do
      {:ok, guard} -> guard
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def enforce(%__MODULE__{decision: :allow}), do: :ok
  def enforce(%__MODULE__{decision: :review} = guard), do: {:review, guard}

  def enforce(%__MODULE__{decision: :deny} = guard) do
    {:error,
     Error.new!(:denied, "guard_denied", "execution was denied by policy",
       source: inspect(__MODULE__),
       details: %{"guard_id" => guard.id, "policies" => guard.policies, "reason" => guard.reason}
     )}
  end

  def encode(%__MODULE__{} = guard),
    do: %{
      "$contract" => @wire_id,
      "id" => guard.id,
      "decision" => Atom.to_string(guard.decision),
      "reason" => guard.reason,
      "policies" => guard.policies,
      "metadata" => guard.metadata
    }

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract") == @wire_id do
      new(map)
    else
      false -> error(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> error([], "guard decision must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  defp decision(value) do
    case Enum.find(@decisions, &(Atom.to_string(&1) == value)) do
      nil -> error(["decision"], "must be allow, deny, or review")
      decision -> {:ok, decision}
    end
  end

  defp identifier?(value), do: is_binary(value) and Regex.match?(~r/^[a-z][a-z0-9_.-]*$/, value)
  defp non_empty?(value), do: is_binary(value) and value != ""
  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
