defmodule RunicAIWeb.AgentLive do
  @moduledoc false

  use RunicAIWeb, :live_view

  import RunicAIWeb.GraphComponents

  alias RunicAI.Workbench
  alias RunicAI.Workbench.Graphs

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:agents, Graphs.agent_index(Workbench.store!()))
     |> assign(:agent, nil)
     |> assign(:selected_node_id, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    agent_id = Map.get(params, "agent_id")
    agent = if agent_id, do: Graphs.agent_detail(Workbench.store!(), agent_id)

    {:noreply,
     socket
     |> assign(:agents, Graphs.agent_index(Workbench.store!()))
     |> assign(:agent, agent)
     |> assign(:selected_node_id, Map.get(params, "node") || first_node_id(agent))}
  end

  @impl true
  def handle_event("select_node", %{"node" => node_id}, socket) do
    {:noreply, assign(socket, :selected_node_id, node_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="runic-workbench min-h-screen overflow-auto text-rune-text">
      <div class="mx-auto grid min-h-screen max-w-[1540px] gap-5 p-[18px]">
        <header class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <p class="font-mono text-[11px] font-bold uppercase text-rune-primary">RunicAI</p>
            <h1 class="font-display text-[30px] font-semibold leading-tight text-rune-text">
              Agent Graphs
            </h1>
          </div>
          <div class="flex items-center gap-2">
            <.link
              patch={~p"/sessions/new"}
              class="inline-flex min-h-[34px] items-center gap-2 rounded-[11px] border border-rune-gold/25 bg-rune-gold/10 px-3 py-2 text-sm font-semibold text-rune-gold"
            >
              <.icon name="hero-plus" class="size-4" /> New session
            </.link>
            <.link
              patch={~p"/"}
              class="inline-flex min-h-[34px] items-center gap-2 rounded-[11px] border border-rune-text/10 bg-black/25 px-3 py-2 text-sm text-rune-text-soft"
            >
              <.icon name="hero-chat-bubble-left-right" class="size-4 text-rune-gold" /> Workbench
            </.link>
          </div>
        </header>

        <section :if={!@agent} class="grid grid-cols-3 gap-4 max-[1050px]:grid-cols-1">
          <.link
            :for={agent <- @agents}
            patch={~p"/agents/#{agent.id}"}
            class="runic-frost rounded-[18px] border border-rune-text/10 bg-black/25 p-5 hover:border-rune-gold/30"
          >
            <div class="mb-4 flex items-start justify-between gap-3">
              <div>
                <h2 class="font-display text-[24px] font-semibold text-rune-text">{agent.name}</h2>
                <p class="mt-2 text-sm leading-6 text-rune-text-soft">{agent.purpose}</p>
              </div>
              <span class="rounded-full bg-rune-primary/15 px-2.5 py-1 font-mono text-[10px] uppercase text-rune-primary">
                {agent.agent}
              </span>
            </div>
            <dl class="grid grid-cols-[128px_1fr] gap-x-3 gap-y-2 font-mono text-[10.5px] text-rune-text-soft">
              <dt class="text-rune-muted">approval</dt>
              <dd>{agent.default_approval}</dd>
              <dt class="text-rune-muted">concurrency</dt>
              <dd>{agent.default_concurrency}</dd>
              <dt class="text-rune-muted">recent</dt>
              <dd>
                {agent.metrics.total_recent} runs / {agent.metrics.failed} failed
              </dd>
            </dl>
          </.link>
        </section>

        <section
          :if={@agent}
          class="grid grid-cols-[minmax(0,1fr)_340px] gap-5 max-[1100px]:grid-cols-1"
        >
          <div class="grid gap-4">
            <div class="runic-frost rounded-[18px] border border-rune-text/10 bg-black/25 p-5">
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <.link patch={~p"/agents"} class="font-mono text-[11px] uppercase text-rune-muted">
                    Agents
                  </.link>
                  <h2 class="mt-2 font-display text-[28px] font-semibold text-rune-text">
                    {@agent.name}
                  </h2>
                  <p class="mt-2 max-w-3xl text-sm leading-6 text-rune-text-soft">
                    {@agent.purpose}
                  </p>
                </div>
                <.link
                  patch={~p"/sessions/new"}
                  class="inline-flex min-h-[36px] items-center gap-2 rounded-[11px] border border-rune-gold/25 bg-rune-gold/10 px-3 py-2 text-sm font-semibold text-rune-gold"
                >
                  <.icon name="hero-play" class="size-4" /> Launch
                </.link>
              </div>
              <div class="mt-4 flex flex-wrap gap-2">
                <span
                  :for={tool <- @agent.tools}
                  class="rounded-full border border-rune-text/10 bg-black/20 px-2.5 py-1 font-mono text-[10.5px] text-rune-text-soft"
                >
                  {tool}
                </span>
              </div>
            </div>

            <.graph_canvas graph={@agent.graph_source} id={"agent-graph-#{@agent.id}"} />
          </div>

          <aside class="grid content-start gap-4">
            <.node_browser
              nodes={@agent.graph_source.nodes}
              selected_node={selected_node(@agent.graph_source.nodes, @selected_node_id)}
            />
            <div class="runic-frost rounded-[18px] border border-rune-text/10 bg-black/20 p-4">
              <h3 class="text-sm font-semibold text-rune-text">Recent runs</h3>
              <div :if={@agent.last_runs == []} class="mt-3 text-sm text-rune-muted">
                No recent runs.
              </div>
              <.link
                :for={run <- @agent.last_runs}
                patch={~p"/sessions/#{run.id}"}
                class="mt-3 grid gap-1 rounded-[12px] bg-black/20 p-3 hover:bg-rune-text/[0.055]"
              >
                <strong class="truncate text-xs text-rune-text">{run.title}</strong>
                <span class="font-mono text-[10.5px] text-rune-muted">{run.status}</span>
              </.link>
            </div>
          </aside>
        </section>
      </div>
    </main>
    """
  end

  defp first_node_id(nil), do: nil
  defp first_node_id(%{graph_source: %{nodes: [%{id: id} | _]}}), do: id
  defp first_node_id(_agent), do: nil

  defp selected_node(nodes, id), do: Enum.find(nodes, &(&1.id == id))
end
