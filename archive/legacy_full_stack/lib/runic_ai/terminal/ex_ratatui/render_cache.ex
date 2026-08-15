defmodule RunicAI.Terminal.ExRatatui.RenderCache do
  @moduledoc """
  Bounded cache for expensive ExRatatui render preparation.

  Widget construction must stay pure and cheap. This cache is updated by reducer
  commands and consumed by views for graph and rich-content fallbacks.
  """

  alias RunicAI.Terminal.GraphPresenter
  alias RunicAI.Terminal.MarkdownBlocks
  alias RunicAI.Terminal.RenderedContent

  @max_entries 100

  @type key :: tuple()
  @type entry :: %{
          key: key(),
          status: atom(),
          output: String.t(),
          warning: String.t() | nil,
          mode: atom(),
          rendered_at: DateTime.t()
        }
  @type t :: %{optional(key()) => entry()}

  @spec new() :: t()
  def new, do: %{}

  @spec graph_sources(map()) :: [map()]
  def graph_sources(model) when is_map(model) do
    artifact_sources(model)
    |> Kernel.++(message_mermaid_sources(model))
    |> Enum.uniq_by(& &1.key)
  end

  @spec markdown_sources(map()) :: [map()]
  def markdown_sources(model) when is_map(model) do
    model
    |> Map.get(:messages, [])
    |> Enum.map(&markdown_source/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec markdown_source(map()) :: map() | nil
  def markdown_source(message) when is_map(message) do
    content = Map.get(message, :content)

    if is_binary(content) and content != "" do
      source_id = Map.get(message, :id) || "message:unknown"

      %{
        key: "message:#{source_id}",
        source_id: source_id,
        content: content
      }
    end
  end

  def markdown_source(_message), do: nil

  @spec render_graph_sources(t(), [map()], keyword()) :: t()
  def render_graph_sources(cache, sources, opts) when is_map(cache) and is_list(sources) do
    Enum.reduce(sources, cache, fn source, acc ->
      key = graph_key(source, opts)

      if Map.has_key?(acc, key) do
        acc
      else
        put(acc, key, render_graph_source(source, opts))
      end
    end)
  end

  @spec render_markdown_sources(t(), [map()], keyword()) :: t()
  def render_markdown_sources(cache, sources, opts) when is_map(cache) and is_list(sources) do
    Enum.reduce(sources, cache, fn source, acc ->
      key = markdown_key(source, opts)

      if Map.has_key?(acc, key) do
        acc
      else
        put(acc, key, render_markdown_source(source))
      end
    end)
  end

  @spec fetch_graph(t(), map(), keyword()) :: entry() | nil
  def fetch_graph(cache, source, opts) when is_map(cache) and is_map(source) do
    Map.get(cache, graph_key(source, opts))
  end

  @spec fetch_markdown(t(), map(), keyword()) :: entry() | nil
  def fetch_markdown(cache, source, opts) when is_map(cache) and is_map(source) do
    Map.get(cache, markdown_key(source, opts))
  end

  @spec mermaid_source_key(term(), String.t()) :: String.t()
  def mermaid_source_key(source_id, source) when is_binary(source) do
    source_id =
      if is_binary(source_id) do
        source_id
      else
        inspect(source_id)
      end

    "message:#{source_id}:#{RenderedContent.content_hash(source)}"
  end

  @spec put(t(), key(), entry()) :: t()
  def put(cache, key, entry) do
    cache
    |> Map.put(key, %{entry | key: key})
    |> trim()
  end

  @spec graph_key(map(), keyword()) :: key()
  def graph_key(source, opts) do
    {
      :graph,
      source.key,
      Keyword.get(opts, :mode, :text),
      Keyword.get(opts, :theme, :runic),
      Keyword.get(opts, :color, :auto)
    }
  end

  @spec markdown_key(map(), keyword()) :: key()
  def markdown_key(source, opts) do
    {
      :markdown,
      source.key,
      RenderedContent.content_hash(source.content || ""),
      Keyword.get(opts, :width, :auto),
      Keyword.get(opts, :theme, :runic),
      Keyword.get(opts, :color, :auto),
      Keyword.get(opts, :unicode, :auto)
    }
  end

  defp render_markdown_source(%{source_id: source_id, content: content}) do
    %{
      key: nil,
      status: :ok,
      output: content,
      warning: nil,
      mode: :markdown,
      blocks: MarkdownBlocks.parse(content, source_id: source_id),
      rendered_at: DateTime.utc_now()
    }
  end

  defp render_graph_source(%{kind: :mermaid, source: source}, opts) do
    mode = Keyword.get(opts, :mode, :text)

    result =
      case mode do
        :text -> %{status: :ok, mode: :text, output: source}
        :mermaid -> %{status: :ok, mode: :mermaid, output: source}
        :mmdflux -> GraphPresenter.render(%{runic: %{serializers: %{mermaid: source}}}, opts)
      end

    entry_from_result(result)
  end

  defp render_graph_source(%{graph: graph}, opts) when is_map(graph) do
    graph
    |> GraphPresenter.render(opts)
    |> entry_from_result()
  end

  defp render_graph_source(%{source: source}, opts) when is_binary(source) do
    render_graph_source(%{kind: :mermaid, source: source}, opts)
  end

  defp render_graph_source(_source, opts) do
    entry_from_result(%{
      status: :blocked,
      mode: Keyword.get(opts, :mode, :text),
      output: "",
      warning: "no renderable graph source"
    })
  end

  defp entry_from_result(result) do
    %{
      key: nil,
      status: Map.get(result, :status, :ok),
      output: Map.get(result, :output, ""),
      warning: Map.get(result, :warning),
      mode: Map.get(result, :mode, :text),
      rendered_at: DateTime.utc_now()
    }
  end

  defp artifact_sources(model) do
    model
    |> Map.get(:artifacts, [])
    |> Enum.filter(&(&1.kind in ["workflow_graph", "workflow_blueprint"]))
    |> Enum.map(&artifact_source/1)
    |> Enum.reject(&is_nil/1)
  end

  defp artifact_source(%{kind: "workflow_graph"} = artifact) do
    graph = artifact.metadata || %{}

    %{
      key: "artifact:#{artifact.id}",
      title: artifact.path || artifact.id,
      kind: :workflow_graph,
      graph: graph
    }
  end

  defp artifact_source(%{kind: "workflow_blueprint"} = artifact) do
    graph = artifact.metadata || %{}

    %{
      key: "artifact:#{artifact.id}",
      title: artifact.path || artifact.id,
      kind: :workflow_blueprint,
      graph: graph
    }
  end

  defp artifact_source(_artifact), do: nil

  defp message_mermaid_sources(model) do
    model
    |> Map.get(:messages, [])
    |> Enum.flat_map(fn message ->
      source_id = message.id || "message"

      message
      |> Map.get(:content, "")
      |> MarkdownBlocks.mermaid_sources(source_id: source_id)
      |> Enum.map(fn %{id: id, source: source} ->
        %{
          key: mermaid_source_key(id, source),
          title: "#{message.role || "message"} Mermaid",
          kind: :mermaid,
          source: source
        }
      end)
    end)
  end

  defp trim(cache) when map_size(cache) <= @max_entries, do: cache

  defp trim(cache) do
    cache
    |> Enum.sort_by(fn {_key, entry} -> DateTime.to_unix(entry.rendered_at, :microsecond) end)
    |> Enum.take(-@max_entries)
    |> Map.new()
  end
end
