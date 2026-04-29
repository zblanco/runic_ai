defmodule RunicAI.Coding.Codex.EventNormalizer do
  @moduledoc """
  Normalizes `codex exec --json` JSONL output into coding trace events.
  """

  alias RunicAI.Coding.TraceRedactor
  alias RunicAI.Error
  alias RunicAI.Trace.Event

  @spec normalize_jsonl(binary()) :: {:ok, map()} | {:error, Error.t()}
  def normalize_jsonl(jsonl) when is_binary(jsonl) do
    decoded =
      jsonl
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{raw_events: [], diagnostics: [], errors: []}, fn line, acc ->
        case decode_line(line) do
          {:ok, event} ->
            %{acc | raw_events: [event | acc.raw_events]}

          {:error, error} ->
            %{
              acc
              | diagnostics: [line | acc.diagnostics],
                errors: [error | acc.errors]
            }
        end
      end)

    case decoded.raw_events do
      [] ->
        {:error,
         List.first(Enum.reverse(decoded.errors)) ||
           Error.validation("codex JSONL output did not contain any events",
             source: __MODULE__,
             details: %{jsonl: jsonl}
           )}

      raw_events ->
        raw_events = Enum.reverse(raw_events)

        {:ok,
         %{
           raw_events: raw_events,
           trace_events: Enum.map(raw_events, &to_trace_event/1),
           final: final_event(raw_events),
           diagnostics: Enum.reverse(decoded.diagnostics)
         }}
    end
  end

  def normalize_jsonl(jsonl) do
    {:error,
     Error.validation("codex JSONL output must be a binary",
       source: __MODULE__,
       details: %{jsonl: jsonl}
     )}
  end

  @spec to_trace_event(map()) :: Event.t()
  def to_trace_event(raw_event) when is_map(raw_event) do
    type = get(raw_event, :type, get(raw_event, :event, "unknown"))
    status = get(raw_event, :status, nil)

    Event.new!(:codex_exec_event,
      status: status,
      input: nil,
      output: TraceRedactor.redact(raw_event),
      metadata: %{codex_event_type: type}
    )
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        {:ok, event}

      {:ok, other} ->
        {:error,
         Error.validation("codex JSONL line must decode to a map",
           source: __MODULE__,
           details: %{line: line, decoded: other}
         )}

      {:error, reason} ->
        {:error,
         Error.validation("could not decode codex JSONL line",
           source: __MODULE__,
           details: %{line: line, reason: Exception.message(reason)}
         )}
    end
  end

  defp final_event(raw_events) do
    Enum.find_value(Enum.reverse(raw_events), &assistant_message/1) ||
      Enum.find_value(Enum.reverse(raw_events), &terminal_event/1) ||
      TraceRedactor.redact(List.last(raw_events) || %{})
  end

  defp assistant_message(event) do
    type = get(event, :type, get(event, :event, nil))
    item = get(event, :item, %{})

    cond do
      type in ["item.completed", "item_completed"] and is_map(item) ->
        item_type = get(item, :type, nil)

        if item_type in ["agent_message", "message"] do
          text =
            first_binary([
              get(item, :text, nil),
              get(item, :content, nil),
              get(item, :message, nil)
            ])

          if text do
            %{"type" => type, "text" => text}
          end
        end

      true ->
        nil
    end
  end

  defp terminal_event(event) do
    type = get(event, :type, get(event, :event, nil))

    if type in ["result", "final", "turn_completed", "done"] do
      TraceRedactor.redact(event)
    end
  end

  defp first_binary(values) do
    Enum.find(values, &(is_binary(&1) and &1 != ""))
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
