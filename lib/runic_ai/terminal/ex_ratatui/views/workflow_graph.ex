defmodule RunicAI.Terminal.ExRatatui.Views.WorkflowGraph do
  @moduledoc false

  alias ExRatatui.Widgets.Paragraph
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.RenderCache
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: Paragraph.t()
  def widget(%Model{} = model) do
    %Paragraph{
      text: graph_text(model),
      block: Helpers.block("Workflow Graph", model),
      style: Theme.style(:text, model),
      wrap: true
    }
  end

  defp graph_text(%Model{} = model) do
    case Model.graph_sources(model) do
      [] ->
        "No persisted graph artifact. mode=#{model.graph}"

      sources ->
        sources
        |> Enum.map(&source_text(&1, model))
        |> Enum.join("\n\n")
    end
  end

  defp source_text(source, %Model{} = model) do
    header = "#{source.title || source.key} / #{model.graph}"

    body =
      case RenderCache.fetch_graph(model.render_cache, source,
             mode: model.graph,
             theme: model.theme
           ) do
        %{warning: warning, output: output} when is_binary(warning) ->
          "graph #{model.graph}: #{warning}\n#{output}"

        %{output: output} when is_binary(output) and output != "" ->
          output

        _other ->
          fallback_source(source, model)
      end

    "#{header}\n#{body}"
  end

  defp fallback_source(%{kind: :mermaid, source: source}, %Model{graph: graph}) do
    if graph == :mmdflux, do: "Rendering with MMDFlux...", else: source
  end

  defp fallback_source(source, _model), do: Helpers.short(Map.get(source, :graph, %{}), 1_200)
end
