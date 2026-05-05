defmodule RunicAI.Terminal.RenderedContent do
  @moduledoc """
  Presentation-neutral content blocks for terminal renderers.

  These blocks are bounded UI projections over durable messages, terminal
  events, artifacts, logs, and live stream fragments. They are intentionally
  plain data so ExRatatui, TermUI, plain CLI, or future surfaces can share the
  same normalization boundary.
  """

  @kinds [
    :markdown,
    :paragraph,
    :heading,
    :list,
    :blockquote,
    :code,
    :diff,
    :table,
    :mermaid,
    :mmdflux,
    :tool_call,
    :tool_result,
    :review_request,
    :scorecard,
    :artifact,
    :error,
    :log,
    :stream_placeholder
  ]

  @enforce_keys [:id, :source_id, :kind, :text]
  defstruct [
    :id,
    :source_id,
    :kind,
    :text,
    :language,
    :status,
    :height_hint,
    :rendered_at,
    metadata: %{},
    stream_complete?: true
  ]

  @type kind ::
          :markdown
          | :paragraph
          | :heading
          | :list
          | :blockquote
          | :code
          | :diff
          | :table
          | :mermaid
          | :mmdflux
          | :tool_call
          | :tool_result
          | :review_request
          | :scorecard
          | :artifact
          | :error
          | :log
          | :stream_placeholder

  @type t :: %__MODULE__{
          id: String.t(),
          source_id: String.t(),
          kind: kind(),
          text: String.t(),
          language: String.t() | nil,
          status: String.t() | atom() | nil,
          metadata: map(),
          stream_complete?: boolean(),
          height_hint: non_neg_integer() | nil,
          rendered_at: DateTime.t() | nil
        }

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    kind = Map.fetch!(attrs, :kind)

    unless kind in @kinds do
      raise ArgumentError, "unknown rendered content kind: #{inspect(kind)}"
    end

    %__MODULE__{
      id: Map.fetch!(attrs, :id),
      source_id: Map.fetch!(attrs, :source_id),
      kind: kind,
      text: Map.get(attrs, :text, ""),
      language: Map.get(attrs, :language),
      status: Map.get(attrs, :status),
      metadata: Map.get(attrs, :metadata, %{}),
      stream_complete?: Map.get(attrs, :stream_complete?, true),
      height_hint: Map.get(attrs, :height_hint),
      rendered_at: Map.get(attrs, :rendered_at)
    }
  end

  @spec from_message(map()) :: t()
  def from_message(message) when is_map(message) do
    role = field(message, :role) || "message"
    kind = field(message, :message_kind) || "message"
    source_id = field(message, :id) || "message:unknown"
    content = field(message, :content) || inspect(field(message, :content_json) || %{})

    new(
      id: "content:#{source_id}",
      source_id: source_id,
      kind: message_kind(role, kind, content),
      text: content || "",
      status: field(message, :status),
      metadata: %{
        role: role,
        message_kind: kind,
        stream_complete: stream_complete?(message)
      },
      stream_complete?: stream_complete?(message)
    )
  end

  @spec from_event(map()) :: t()
  def from_event(event) when is_map(event) do
    source_id = field(event, :id) || "event:unknown"
    kind = field(event, :kind) || "event"
    status = field(event, :status)
    text = field(event, :detail) || field(event, :title) || inspect(field(event, :data) || %{})

    new(
      id: "content:#{source_id}",
      source_id: source_id,
      kind: event_kind(kind, status),
      text: text || "",
      status: status,
      metadata: %{event_kind: kind, phase: field(event, :phase)}
    )
  end

  @spec from_artifact(map()) :: t()
  def from_artifact(artifact) when is_map(artifact) do
    source_id = field(artifact, :id) || "artifact:unknown"
    kind = field(artifact, :kind) || "artifact"
    path = field(artifact, :path)
    metadata = field(artifact, :metadata) || %{}

    new(
      id: "content:#{source_id}",
      source_id: source_id,
      kind: artifact_kind(kind),
      text: path || inspect(metadata, limit: 10, printable_limit: 2_000),
      status: field(artifact, :action),
      metadata: metadata
    )
  end

  @spec from_log(map()) :: t()
  def from_log(log) when is_map(log) do
    source_id = field(log, :id) || "log:#{System.unique_integer([:positive])}"

    new(
      id: "content:#{source_id}",
      source_id: source_id,
      kind: :log,
      text: field(log, :message) |> to_string(),
      status: field(log, :level),
      metadata: log
    )
  end

  @spec content_hash(String.t()) :: String.t()
  def content_hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
  end

  defp message_kind(_role, "error", _content), do: :error
  defp message_kind(_role, "review_request", _content), do: :review_request
  defp message_kind(_role, "stream", _content), do: :markdown

  defp message_kind(_role, _kind, content),
    do: if(markdown?(content), do: :markdown, else: :paragraph)

  defp event_kind("tool", _status), do: :tool_call
  defp event_kind("hitl", _status), do: :review_request
  defp event_kind("summary", _status), do: :scorecard
  defp event_kind(_kind, status) when status in ["error", :error], do: :error
  defp event_kind(_kind, _status), do: :paragraph

  defp artifact_kind("workflow_graph"), do: :mermaid
  defp artifact_kind("workflow_blueprint"), do: :artifact
  defp artifact_kind(_kind), do: :artifact

  defp stream_complete?(message) do
    case field(message, :stream_complete) do
      nil -> field(message, :stream_complete?) != false
      value -> value
    end
  end

  defp markdown?(text) when is_binary(text) do
    String.contains?(text, ["# ", "## ", "- ", "* ", "```", "|", "**", "__", "> "])
  end

  defp markdown?(_text), do: false

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
