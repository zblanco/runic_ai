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

      <section
        :if={contract_review?(@graph)}
        class="runic-frost rounded-[18px] border border-rune-text/10 bg-black/20 p-4"
        aria-label="Workflow proposal contract review"
      >
        <div class="flex flex-wrap items-end justify-between gap-2">
          <div>
            <h4 class="text-sm font-semibold text-rune-text">Proposal contract review</h4>
            <p class="mt-1 text-xs text-rune-muted">
              Read-only component contracts, effects, policies, and acceptance.
            </p>
          </div>
          <span class="font-mono text-[10.5px] uppercase text-rune-muted">
            {length(@graph.nodes)} components
          </span>
        </div>

        <div class="mt-3 grid gap-2">
          <article
            :for={node <- @graph.nodes}
            class="rounded-[13px] border border-rune-text/10 bg-black/20 px-3 py-2.5"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <strong class="text-xs text-rune-text">{node.label}</strong>
              <span class="font-mono text-[10px] text-rune-muted">
                {Map.get(node, :kind) || "component"} / {Map.get(node, :execution_shape) || "step"}
              </span>
            </div>
            <dl class="mt-2 grid grid-cols-[70px_1fr] gap-x-2 gap-y-1 font-mono text-[10.5px] text-rune-text-soft">
              <dt class="text-rune-muted">inputs</dt>
              <dd>{port_names(Map.get(node, :inputs))}</dd>
              <dt class="text-rune-muted">outputs</dt>
              <dd>{port_names(Map.get(node, :outputs))}</dd>
              <dt class="text-rune-muted">effects</dt>
              <dd>{list_summary(Map.get(node, :effects), "none declared")}</dd>
              <dt class="text-rune-muted">replay</dt>
              <dd>{replay_summary(Map.get(node, :replay))}</dd>
              <dt class="text-rune-muted">policies</dt>
              <dd>{policy_summary(Map.get(node, :policy))}</dd>
            </dl>
          </article>
        </div>

        <div
          :if={Map.get(@graph, :acceptance, []) != []}
          class="mt-3 border-t border-rune-text/10 pt-3"
        >
          <div class="font-mono text-[10px] font-bold uppercase text-rune-muted">Acceptance</div>
          <ul class="mt-2 grid gap-1 text-xs text-rune-text-soft">
            <li :for={condition <- @graph.acceptance}>- {acceptance_summary(condition)}</li>
          </ul>
        </div>
      </section>

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

  defp replay_summary(replay) when is_map(replay) do
    strategy = Map.get(replay, :strategy, Map.get(replay, "strategy", "unspecified"))
    automatic? = Map.get(replay, :automatic_retry?, Map.get(replay, "automatic_retry?"))

    case automatic? do
      true -> "#{strategy}; automatic retry allowed"
      false -> "#{strategy}; manual reconciliation required"
      _other -> to_string(strategy)
    end
  end

  defp replay_summary(_replay), do: "unspecified"

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

  defp contract_review?(graph) do
    Enum.any?(Map.get(graph, :nodes, []), fn node ->
      Map.get(node, :execution_shape) || Map.get(node, :inputs, %{}) != %{} ||
        Map.get(node, :outputs, %{}) != %{} || Map.get(node, :effects, []) != [] ||
        Map.get(node, :policy, %{}) != %{}
    end) or Map.get(graph, :acceptance, []) != []
  end

  defp port_names(ports) when is_map(ports) and map_size(ports) > 0,
    do: ports |> Map.keys() |> Enum.map_join(", ", &to_string/1)

  defp port_names(ports) when is_list(ports) and ports != [] do
    Enum.map_join(ports, ", ", fn
      {name, _contract} -> to_string(name)
      %{"name" => name} -> to_string(name)
      %{name: name} -> to_string(name)
      name -> to_string(name)
    end)
  end

  defp port_names(_ports), do: "none"

  defp list_summary(values, fallback) do
    case List.wrap(values) do
      [] -> fallback
      values -> Enum.map_join(values, ", ", &to_string/1)
    end
  end

  defp policy_summary(policy) when is_map(policy) and map_size(policy) > 0,
    do: policy |> Map.keys() |> Enum.map_join(", ", &to_string/1)

  defp policy_summary(_policy), do: "defaults"

  defp acceptance_summary(condition) when is_map(condition) do
    Map.get(condition, :description) || Map.get(condition, "description") ||
      Map.get(condition, :condition) || Map.get(condition, "condition") ||
      Map.get(condition, :id) || Map.get(condition, "id") || inspect(condition)
  end

  defp acceptance_summary(condition), do: to_string(condition)
end
