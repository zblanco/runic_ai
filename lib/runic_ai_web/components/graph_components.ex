defmodule RunicAIWeb.GraphComponents do
  @moduledoc false

  use RunicAIWeb, :html

  attr :graph, :map, required: true
  attr :id, :string, required: true

  def graph_canvas(assigns) do
    ~H"""
    <section class="grid min-h-0 gap-4">
      <div class="runic-frost overflow-hidden rounded-[18px] border border-rune-text/10 bg-black/25">
        <div class="flex flex-wrap items-center justify-between gap-3 border-b border-rune-text/10 px-4 py-3">
          <div class="min-w-0">
            <h3 class="truncate text-sm font-semibold text-rune-text">{@graph.title}</h3>
            <p class="mt-1 font-mono text-[10.5px] text-rune-muted">
              {length(@graph.nodes)} nodes - {length(@graph.edges)} edges - hash {@graph.source_hash}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button
              id={"#{@id}-copy-svg"}
              type="button"
              phx-hook="GraphCopy"
              data-copy-selector={"##{@id} .runic-mermaid-output svg"}
              class="inline-flex min-h-[32px] items-center gap-1.5 rounded-[10px] border border-rune-text/10 bg-black/25 px-2.5 py-1.5 font-mono text-[10.5px] text-rune-text-soft hover:border-rune-gold/35"
            >
              <.icon name="hero-clipboard-document" class="size-3.5 text-rune-gold" /> SVG
            </button>
            <button
              id={"#{@id}-copy-source"}
              type="button"
              phx-hook="GraphCopy"
              data-copy-selector={"##{@id} [data-graph-source]"}
              class="inline-flex min-h-[32px] items-center gap-1.5 rounded-[10px] border border-rune-text/10 bg-black/25 px-2.5 py-1.5 font-mono text-[10.5px] text-rune-text-soft hover:border-rune-gold/35"
            >
              <.icon name="hero-code-bracket" class="size-3.5 text-rune-gold" /> Source
            </button>
          </div>
        </div>
        <div
          id={@id}
          phx-hook="MermaidGraph"
          data-graph-hash={@graph.source_hash}
          class="min-h-[360px] p-4"
        >
          <pre class="hidden" data-graph-source phx-no-format><%= @graph.mermaid %></pre>
          <div class="runic-mermaid-status mb-3 font-mono text-[10.5px] text-rune-muted">
            Rendering Mermaid dark graph...
          </div>
          <div class="runic-mermaid-output runic-scrollbar overflow-auto rounded-[14px] bg-black/20 p-4" />
        </div>
      </div>

      <details class="runic-frost rounded-[18px] border border-rune-text/10 bg-black/20 p-4" open>
        <summary class="cursor-pointer font-mono text-[11px] font-bold uppercase text-rune-muted">
          Source fallback
        </summary>
        <pre class="runic-scrollbar mt-3 max-h-[240px] overflow-auto whitespace-pre-wrap rounded-[12px] bg-black/25 p-3 font-mono text-[11px] leading-5 text-rune-text-soft"><code>{@graph.mermaid}</code></pre>
        <pre class="runic-scrollbar mt-3 max-h-[180px] overflow-auto whitespace-pre-wrap rounded-[12px] bg-black/25 p-3 font-mono text-[11px] leading-5 text-rune-muted"><code>{@graph.fallback}</code></pre>
      </details>
    </section>
    """
  end

  attr :nodes, :list, required: true
  attr :selected_node, :map, default: nil
  attr :click, :string, default: "select_node"

  def node_browser(assigns) do
    ~H"""
    <div class="runic-frost rounded-[18px] border border-rune-text/10 bg-black/20">
      <div class="border-b border-rune-text/10 px-4 py-3">
        <h3 class="text-sm font-semibold text-rune-text">Node inspector</h3>
        <p class="mt-1 font-mono text-[10.5px] text-rune-muted">Select a graph node</p>
      </div>
      <div class="grid max-h-[260px] gap-1 overflow-auto p-2 runic-scrollbar">
        <button
          :for={node <- @nodes}
          type="button"
          phx-click={@click}
          phx-value-node={node.id}
          class={[
            "grid grid-cols-[1fr_auto] gap-2 rounded-[11px] px-3 py-2 text-left hover:bg-rune-text/[0.055]",
            @selected_node && @selected_node.id == node.id && "bg-rune-primary/10"
          ]}
        >
          <span class="min-w-0">
            <strong class="block truncate text-xs text-rune-text">{node.label}</strong>
            <span class="mt-1 block truncate font-mono text-[10.5px] text-rune-muted">
              {node.id} - {node.kind || "node"}
            </span>
          </span>
          <span class={[
            "h-fit rounded-full px-2 py-1 font-mono text-[10px]",
            node_status_class(node.status)
          ]}>
            {node.status || "static"}
          </span>
        </button>
      </div>
      <div class="border-t border-rune-text/10 p-4">
        <div :if={!@selected_node} class="text-sm text-rune-muted">No node selected.</div>
        <div :if={@selected_node} class="grid gap-2">
          <div class="font-mono text-[10.5px] uppercase text-rune-muted">selected</div>
          <h4 class="text-sm font-semibold text-rune-text">{@selected_node.label}</h4>
          <dl class="grid grid-cols-[88px_1fr] gap-x-3 gap-y-1.5 font-mono text-[10.5px] text-rune-text-soft">
            <dt class="text-rune-muted">id</dt>
            <dd class="truncate">{@selected_node.id}</dd>
            <dt class="text-rune-muted">kind</dt>
            <dd>{@selected_node.kind || "-"}</dd>
            <dt class="text-rune-muted">status</dt>
            <dd>{@selected_node.status || "static"}</dd>
            <dt class="text-rune-muted">sequence</dt>
            <dd>{get_in(@selected_node, [:events, :sequence]) || "-"}</dd>
            <dt class="text-rune-muted">stage</dt>
            <dd>{get_in(@selected_node, [:events, :stage]) || "-"}</dd>
          </dl>
        </div>
      </div>
    </div>
    """
  end

  defp node_status_class(status) when status in ["ok", "completed", "approved"],
    do: "bg-rune-success/15 text-rune-success"

  defp node_status_class(status) when status in ["running", "review", "waiting"],
    do: "bg-rune-primary/15 text-rune-primary"

  defp node_status_class(status) when status in ["failed", "error", "blocked", "denied"],
    do: "bg-rune-error/15 text-rune-error"

  defp node_status_class(_status), do: "bg-rune-text/10 text-rune-text-soft"
end
