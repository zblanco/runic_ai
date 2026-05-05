defmodule RunicAI.Terminal.StreamBuffer do
  @moduledoc """
  Bounded stream buffer for terminal conversation panes.

  The buffer tracks incremental content by stable stream id. Durable storage is
  still owned by persistence; this module only gives the live TUI a coherent
  in-progress projection.
  """

  @max_streams 25
  @max_content_bytes 120_000

  @type stream_id :: String.t()
  @type buffer :: %{
          id: stream_id(),
          run_id: String.t() | nil,
          message_id: String.t(),
          role: String.t(),
          message_kind: String.t(),
          content: String.t(),
          status: String.t(),
          stream_complete: boolean(),
          sequence: non_neg_integer(),
          updated_at: DateTime.t()
        }

  @type buffers :: %{optional(stream_id()) => buffer()}

  @spec new() :: buffers()
  def new, do: %{}

  @spec append(buffers(), map()) :: {buffers(), map()}
  def append(buffers, attrs) when is_map(buffers) and is_map(attrs) do
    now = Map.get(attrs, :at) || DateTime.utc_now()
    id = stream_id(attrs)
    complete? = Map.get(attrs, :complete?, Map.get(attrs, :stream_complete, false))
    status = stream_status(attrs, complete?)
    chunk = chunk_text(attrs) <> status_marker(status, attrs)

    buffer =
      buffers
      |> Map.get(id, base_buffer(id, attrs, now))
      |> append_chunk(chunk, complete? or terminal_status?(status), status, now)

    buffers =
      buffers
      |> Map.put(id, buffer)
      |> trim_buffers()

    {buffers, message(buffer)}
  end

  @spec finalize(buffers(), map()) :: {buffers(), map()}
  def finalize(buffers, attrs) do
    append(buffers, attrs |> Map.put(:complete?, true) |> Map.put_new(:status, "ok"))
  end

  @spec fail(buffers(), map()) :: {buffers(), map()}
  def fail(buffers, attrs) do
    append(
      buffers,
      attrs
      |> Map.put(:complete?, true)
      |> Map.put(:status, "error")
    )
  end

  @spec interrupt(buffers(), map()) :: {buffers(), map()}
  def interrupt(buffers, attrs) do
    append(
      buffers,
      attrs
      |> Map.put(:complete?, true)
      |> Map.put(:status, "interrupted")
    )
  end

  @spec message(buffer()) :: map()
  def message(buffer) when is_map(buffer) do
    %{
      id: buffer.message_id,
      conversation_id: "conversation:#{buffer.run_id || buffer.id}",
      session_id: buffer.run_id || buffer.id,
      role: buffer.role,
      message_kind: buffer.message_kind,
      source_step: "stream",
      workflow_node: nil,
      content: buffer.content,
      content_json: %{stream_id: buffer.id, status: buffer.status},
      stream_complete: buffer.stream_complete,
      transient: not buffer.stream_complete,
      presentation_group_id: buffer.run_id || buffer.id,
      created_at: buffer.updated_at
    }
  end

  defp base_buffer(id, attrs, now) do
    run_id = Map.get(attrs, :run_id) || Map.get(attrs, "run_id")

    %{
      id: id,
      run_id: run_id,
      message_id: Map.get(attrs, :message_id) || Map.get(attrs, "message_id") || "stream:#{id}",
      role: Map.get(attrs, :role) || Map.get(attrs, "role") || "assistant",
      message_kind: Map.get(attrs, :message_kind) || Map.get(attrs, "message_kind") || "stream",
      content: "",
      status: "running",
      stream_complete: false,
      sequence: 0,
      updated_at: now
    }
  end

  defp append_chunk(buffer, chunk, complete?, status, now) do
    content =
      (buffer.content <> chunk)
      |> truncate_bytes(@max_content_bytes)

    %{
      buffer
      | content: content,
        status: status,
        stream_complete: complete?,
        sequence: buffer.sequence + 1,
        updated_at: now
    }
  end

  defp stream_id(attrs) do
    Map.get(attrs, :stream_id) || Map.get(attrs, "stream_id") || Map.get(attrs, :message_id) ||
      Map.get(attrs, "message_id") || "default"
  end

  defp chunk_text(attrs) do
    Map.get(attrs, :chunk) || Map.get(attrs, "chunk") || Map.get(attrs, :content) ||
      Map.get(attrs, "content") || ""
  end

  defp stream_status(attrs, true) do
    attrs
    |> Map.get(:status, Map.get(attrs, "status", "ok"))
    |> to_string()
  end

  defp stream_status(attrs, false) do
    attrs
    |> Map.get(:status, Map.get(attrs, "status", "running"))
    |> to_string()
  end

  defp terminal_status?(status), do: status in ["error", "failed", "interrupted"]

  defp status_marker(status, attrs) when status in ["error", "failed"] do
    marker = "[stream failed: #{status_reason(attrs, status)}]"
    if chunk_text(attrs) == "", do: marker, else: "\n#{marker}"
  end

  defp status_marker("interrupted", attrs) do
    marker = "[stream interrupted: #{status_reason(attrs, "interrupted")}]"
    if chunk_text(attrs) == "", do: marker, else: "\n#{marker}"
  end

  defp status_marker(_status, _attrs), do: ""

  defp status_reason(attrs, fallback) do
    attrs
    |> Map.get(:reason, Map.get(attrs, "reason", Map.get(attrs, :error, Map.get(attrs, "error"))))
    |> case do
      nil -> fallback
      value -> value |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    end
  end

  defp trim_buffers(buffers) when map_size(buffers) <= @max_streams, do: buffers

  defp trim_buffers(buffers) do
    buffers
    |> Enum.sort_by(fn {_id, buffer} -> DateTime.to_unix(buffer.updated_at, :microsecond) end)
    |> Enum.take(-@max_streams)
    |> Map.new()
  end

  defp truncate_bytes(text, limit) when byte_size(text) <= limit, do: text

  defp truncate_bytes(text, limit) do
    omitted = "\n[stream truncated]"
    keep = max(limit - byte_size(omitted), 0)

    text
    |> binary_part(byte_size(text) - keep, keep)
    |> valid_utf8_suffix()
    |> then(&(omitted <> &1))
  end

  defp valid_utf8_suffix(text) do
    if String.valid?(text) or byte_size(text) == 0 do
      text
    else
      text
      |> binary_part(1, byte_size(text) - 1)
      |> valid_utf8_suffix()
    end
  end
end
