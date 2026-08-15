defmodule RunicAI.Control.Trace do
  @moduledoc "Ordered, portable execution trace with explicitly supplied timestamps."

  alias RunicAI.JSONValue
  alias RunicAI.Control.Trace.Event

  @wire_id "runic.ai/trace/v1"
  @event_wire "runic.ai/trace-event/v1"
  @statuses [:started, :succeeded, :failed, :suspended, :resumed, :skipped]

  @enforce_keys [:run_id, :events]
  defstruct run_id: nil, events: []
  @type t :: %__MODULE__{run_id: String.t(), events: [Event.t()]}

  def new(run_id) when is_binary(run_id) and run_id != "",
    do: %__MODULE__{run_id: run_id, events: []}

  def event(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         {:ok, status} <- status(map["status"]),
         true <- non_empty?(map["id"]) and non_empty?(map["component"]),
         true <- is_integer(map["sequence"]) and map["sequence"] >= 0,
         true <- non_empty?(map["occurred_at"]),
         metadata when is_map(metadata) <- Map.get(map, "metadata", %{}) do
      {:ok,
       %Event{
         id: map["id"],
         sequence: map["sequence"],
         component: map["component"],
         status: status,
         occurred_at: map["occurred_at"],
         input_ref: map["input_ref"],
         output_ref: map["output_ref"],
         error: map["error"],
         metadata: metadata
       }}
    else
      false -> error([], "trace event fields are invalid")
      {:ok, _other} -> error([], "trace event must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def event!(input), do: unwrap!(event(input))

  def append(%__MODULE__{} = trace, %Event{} = event) do
    expected = length(trace.events)

    if event.sequence == expected and Enum.all?(trace.events, &(&1.id != event.id)) do
      {:ok, %{trace | events: trace.events ++ [event]}}
    else
      error(["sequence"], "must be the next unique trace sequence")
    end
  end

  def encode(%__MODULE__{} = trace),
    do: %{
      "$contract" => @wire_id,
      "run_id" => trace.run_id,
      "events" => Enum.map(trace.events, &encode/1)
    }

  def encode(%Event{} = event),
    do:
      compact(%{
        "$contract" => @event_wire,
        "id" => event.id,
        "sequence" => event.sequence,
        "component" => event.component,
        "status" => Atom.to_string(event.status),
        "occurred_at" => event.occurred_at,
        "input_ref" => event.input_ref,
        "output_ref" => event.output_ref,
        "error" => event.error,
        "metadata" => event.metadata
      })

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- map["$contract"] == @wire_id,
         true <- non_empty?(map["run_id"]),
         events when is_list(events) <- map["events"],
         {:ok, decoded} <- decode_events(events) do
      Enum.reduce_while(decoded, {:ok, new(map["run_id"])}, fn item, {:ok, trace} ->
        case append(trace, item) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, issues} -> {:halt, {:error, issues}}
        end
      end)
    else
      false -> error([], "trace fields are invalid")
      {:ok, _other} -> error([], "trace must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  defp decode_events(events) do
    Enum.reduce_while(events, {:ok, []}, fn item, {:ok, acc} ->
      case event(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, issues} -> {:halt, {:error, issues}}
      end
    end)
  end

  defp status(value) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == value)) do
      nil -> error(["status"], "is not supported")
      status -> {:ok, status}
    end
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp non_empty?(value), do: is_binary(value) and value != ""
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, issues}), do: raise(ArgumentError, inspect(issues))
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
