defmodule RunicAIWeb.GraphLive do
  @moduledoc false

  use RunicAIWeb, :live_view

  import RunicAIWeb.GraphComponents

  alias RunicAI.Workbench
  alias RunicAI.Workbench.Graphs

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Workflow Graph")
     |> assign(:graph, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    run_id = Map.fetch!(params, "run_id")

    graph =
      Workbench.store!()
      |> Graphs.run_graph(run_id, kind: Map.get(params, "graph"), node: Map.get(params, "node"))

    {:noreply, assign(socket, :graph, graph)}
  end

  @impl true
  def handle_event("set_graph_kind", %{"kind" => kind}, socket) do
    graph = socket.assigns.graph
    {:noreply, push_patch(socket, to: ~p"/runs/#{graph.run_id}/graph?graph=#{kind}")}
  end

  def handle_event("select_node", %{"node" => node_id}, socket) do
    graph = socket.assigns.graph

    {:noreply,
     push_patch(socket, to: ~p"/runs/#{graph.run_id}/graph?graph=#{graph.kind}&node=#{node_id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="runic-workbench min-h-screen overflow-auto text-rune-text">
      <div class="mx-auto grid min-h-screen max-w-[1600px] grid-rows-[auto_1fr] gap-5 p-[18px]">
        <header class="flex flex-wrap items-center justify-between gap-4">
          <div class="min-w-0">
            <p class="font-mono text-[11px] font-bold uppercase text-rune-primary">
              Run {@graph.run_id}
            </p>
            <h1 class="truncate font-display text-[30px] font-semibold leading-tight text-rune-text">
              Workflow Graph
            </h1>
          </div>
          <div class="flex items-center gap-2">
            <.link
              patch={~p"/sessions/#{@graph.run_id}"}
              class="inline-flex min-h-[34px] items-center gap-2 rounded-[11px] border border-rune-text/10 bg-black/25 px-3 py-2 text-sm text-rune-text-soft"
            >
              <.icon name="hero-chat-bubble-left-right" class="size-4 text-rune-gold" /> Session
            </.link>
            <.link
              patch={~p"/agents"}
              class="inline-flex min-h-[34px] items-center gap-2 rounded-[11px] border border-rune-text/10 bg-black/25 px-3 py-2 text-sm text-rune-text-soft"
            >
              <.icon name="hero-cpu-chip" class="size-4 text-rune-gold" /> Agents
            </.link>
          </div>
        </header>

        <section class="grid min-h-0 grid-cols-[minmax(0,1fr)_360px] gap-5 max-[1100px]:grid-cols-1">
          <div class="grid min-h-0 content-start gap-4">
            <div class="runic-frost flex flex-wrap items-center justify-between gap-3 rounded-[18px] border border-rune-text/10 bg-black/25 p-3">
              <div class="flex flex-wrap items-center gap-1 rounded-[14px] border border-rune-text/5 bg-black/25 p-1">
                <button
                  :for={source <- @graph.available_sources}
                  type="button"
                  phx-click="set_graph_kind"
                  phx-value-kind={source.id}
                  class={[
                    "inline-flex min-h-[34px] items-center gap-2 rounded-[10px] px-3 py-1.5 font-mono text-[11px]",
                    @graph.kind == source.id && "bg-rune-text/10 text-rune-text",
                    @graph.kind != source.id && "text-rune-muted hover:bg-rune-text/[0.06]"
                  ]}
                >
                  {source.label}
                </button>
              </div>
              <div class="font-mono text-[10.5px] text-rune-muted">
                selected: {@graph.kind}
              </div>
            </div>

            <.graph_canvas graph={@graph} id={"run-graph-#{dom_id(@graph.run_id)}"} />
          </div>

          <aside class="grid content-start gap-4">
            <.node_browser nodes={@graph.nodes} selected_node={@graph.selected_node} />

            <div class="runic-frost rounded-[18px] border border-rune-text/10 bg-black/20 p-4">
              <h3 class="text-sm font-semibold text-rune-text">Graph metadata</h3>
              <dl class="mt-3 grid grid-cols-[126px_1fr] gap-x-3 gap-y-2 font-mono text-[10.5px] text-rune-text-soft">
                <dt class="text-rune-muted">source</dt>
                <dd>{@graph.kind}</dd>
                <dt class="text-rune-muted">nodes</dt>
                <dd>{length(@graph.nodes)}</dd>
                <dt class="text-rune-muted">edges</dt>
                <dd>{length(@graph.edges)}</dd>
                <dt class="text-rune-muted">hash</dt>
                <dd class="truncate">{@graph.source_hash}</dd>
                <div :for={{key, value} <- @graph.metadata} class="contents">
                  <dt class="text-rune-muted">{key}</dt>
                  <dd class="truncate">{inspect(value)}</dd>
                </div>
              </dl>
            </div>
          </aside>
        </section>
      </div>
    </main>
    """
  end

  defp dom_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end
end
