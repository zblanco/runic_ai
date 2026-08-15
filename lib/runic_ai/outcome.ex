defmodule RunicAI.Outcome do
  @moduledoc "Stable public control envelope for component and workflow boundaries."

  alias RunicAI.Error
  alias RunicAI.JSONValue

  @wire_id "runic.ai/outcome/v1"
  @kinds [:success, :retry, :failure, :wait, :review, :cancelled, :completed, :progress]
  @terminal [:success, :failure, :cancelled, :completed]

  @enforce_keys [:kind]
  defstruct kind: nil, value: nil, error: nil, control: nil, evidence: [], trace: %{}

  @type t :: %__MODULE__{}

  def new(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         {:ok, kind} <- decode_kind(map["kind"]),
         {:ok, error} <- decode_error(map["error"]),
         evidence when is_list(evidence) <- Map.get(map, "evidence", []),
         trace when is_map(trace) <- Map.get(map, "trace", %{}) do
      {:ok,
       %__MODULE__{
         kind: kind,
         value: map["value"],
         error: error,
         control: map["control"],
         evidence: evidence,
         trace: trace
       }}
    else
      {:ok, _other} -> issue([], "outcome must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def new!(input) do
    case new(input) do
      {:ok, outcome} -> outcome
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def terminal?(%__MODULE__{kind: kind}), do: kind in @terminal

  def encode(%__MODULE__{} = outcome),
    do:
      %{
        "$contract" => @wire_id,
        "kind" => Atom.to_string(outcome.kind),
        "evidence" => outcome.evidence,
        "trace" => outcome.trace
      }
      |> put_if("value", outcome.value)
      |> put_if("error", if(outcome.error, do: Error.encode(outcome.error)))
      |> put_if("control", outcome.control)

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- map["$contract"] == @wire_id do
      new(map)
    else
      false -> issue(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> issue([], "outcome must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def select(events) when is_list(events) do
    Enum.reduce(events, nil, fn event, selected ->
      cond do
        is_nil(selected) -> event
        terminal?(selected) -> selected
        terminal?(event) -> event
        true -> event
      end
    end)
  end

  defp decode_kind(value) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == value)) do
      nil -> issue(["kind"], "is not supported")
      kind -> {:ok, kind}
    end
  end

  defp decode_error(nil), do: {:ok, nil}
  defp decode_error(value), do: Error.decode(value)
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
  defp issue(path, message), do: {:error, [%{path: path, message: message}]}
end
