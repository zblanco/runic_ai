defmodule RunicAIWeb.DebugLive do
  @moduledoc false

  use RunicAIWeb, :live_view

  alias RunicAI.Workbench
  alias RunicAI.Workbench.Debug

  @tabs [
    logs: {"Logs", "hero-list-bullet"},
    traces: {"Traces", "hero-chart-bar-square"},
    managed: {"Managed", "hero-arrow-path-rounded-square"},
    scorecards: {"Scorecards", "hero-clipboard-document-check"},
    context: {"Context", "hero-document-magnifying-glass"},
    health: {"Health", "hero-heart"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Debug Workbench")
     |> assign(:tabs, @tabs)
     |> assign(:filters, %{})
     |> assign(:data, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action || :logs
    store = Workbench.store!()

    data =
      case action do
        :logs -> Debug.logs(store, params)
        :traces -> Debug.traces(store, params)
        :managed -> Debug.managed_workflows(store, params)
        :scorecards -> Debug.scorecards(store, params)
        :context -> Debug.context(store, params)
        :health -> Debug.health(store)
      end

    filters = Map.get(data, :filters, %{})

    {:noreply,
     socket
     |> assign(:page_title, page_title(action))
     |> assign(:filters, filters)
     |> assign(:data, data)}
  end

  @impl true
  def handle_event("filter_debug", %{"filters" => filters}, socket) do
    {:noreply,
     push_patch(socket,
       to: debug_path(socket.assigns.live_action, Map.put(filters, "page", "1"))
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <main class="runic-workbench min-h-screen overflow-auto text-rune-text">
      <div class="mx-auto grid min-h-screen max-w-[1600px] grid-rows-[auto_auto_1fr] gap-5 p-[18px]">
        <header class="flex flex-wrap items-center justify-between gap-4">
          <div class="min-w-0">
            <p class="font-mono text-[11px] font-bold uppercase text-rune-primary">RunicAI</p>
            <h1 class="truncate font-display text-[30px] font-semibold leading-tight text-rune-text">
              {@page_title}
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

        <nav class="runic-frost flex flex-wrap items-center gap-1 rounded-[18px] border border-rune-text/10 bg-black/25 p-2">
          <.link
            :for={{tab, {label, icon}} <- @tabs}
            patch={debug_path(tab, filter_params(@filters))}
            class={[
              "inline-flex min-h-[34px] items-center gap-2 rounded-[10px] px-3 py-1.5 text-sm",
              @live_action == tab && "bg-rune-text/10 text-rune-text",
              @live_action != tab && "text-rune-muted hover:bg-rune-text/[0.06]"
            ]}
          >
            <.icon name={icon} class="size-4 text-rune-gold" /> {label}
          </.link>
        </nav>

        <section class="grid min-h-0 gap-5">
          <.filters action={@live_action} filters={@filters} />

          <.logs_view :if={@live_action == :logs} data={@data} />
          <.traces_view :if={@live_action == :traces} data={@data} />
          <.managed_view :if={@live_action == :managed} data={@data} />
          <.scorecards_view :if={@live_action == :scorecards} data={@data} />
          <.context_view :if={@live_action == :context} data={@data} />
          <.health_view :if={@live_action == :health} data={@data} />
        </section>
      </div>
    </main>
    """
  end

  defp filters(assigns) do
    ~H"""
    <form
      :if={@action != :health}
      phx-change="filter_debug"
      class="runic-frost grid grid-cols-[repeat(6,minmax(110px,1fr))_86px] gap-2 rounded-[18px] border border-rune-text/10 bg-black/20 p-3 max-[1000px]:grid-cols-2"
    >
      <.filter_input label="Run" name="run_id" value={@filters[:run_id]} />
      <.filter_input label="Session" name="session_id" value={@filters[:session_id]} />
      <.filter_input label="Kind" name="kind" value={@filters[:kind]} />
      <.filter_input label="Status" name="status" value={@filters[:status]} />
      <.filter_input label="Phase" name="phase" value={@filters[:phase]} />
      <.filter_input label="Search" name="q" value={@filters[:q]} />
      <label class="grid gap-1">
        <span class="font-mono text-[10px] uppercase text-rune-muted">Limit</span>
        <input
          name="filters[limit]"
          value={@filters[:limit] || 40}
          type="number"
          min="1"
          max="100"
          class="min-h-[34px] rounded-[10px] border border-rune-text/10 bg-black/25 px-2 font-mono text-[11px] text-rune-text outline-none focus:border-rune-gold/45"
        />
      </label>
      <input type="hidden" name="filters[page]" value={@filters[:page] || 1} />
    </form>
    """
  end

  defp filter_input(assigns) do
    ~H"""
    <label class="grid gap-1">
      <span class="font-mono text-[10px] uppercase text-rune-muted">{@label}</span>
      <input
        name={"filters[#{@name}]"}
        value={@value || ""}
        autocomplete="off"
        class="min-h-[34px] rounded-[10px] border border-rune-text/10 bg-black/25 px-2 font-mono text-[11px] text-rune-text outline-none focus:border-rune-gold/45"
      />
    </label>
    """
  end

  defp logs_view(assigns) do
    ~H"""
    <.panel title="Logs" data={@data}>
      <:actions>
        <.export_link filters={@data.filters} />
      </:actions>
      <.event_table rows={@data.rows} />
      <.pager data={@data} action={:logs} />
    </.panel>
    """
  end

  defp traces_view(assigns) do
    ~H"""
    <div class="grid grid-cols-3 gap-4 max-[1200px]:grid-cols-1">
      <.panel title="Terminal Events" data={@data.terminal}>
        <:actions><.export_link filters={@data.filters} /></:actions>
        <.event_table rows={@data.terminal.rows} />
        <.pager data={@data.terminal} action={:traces} />
      </.panel>
      <.panel title="Runnable Lifecycle" data={@data.runnable}>
        <.kv_rows
          rows={@data.runnable.rows}
          keys={[:sequence, :node_name, :component_type, :stage, :status]}
        />
      </.panel>
      <.panel title="Workflow Events" data={@data.workflow}>
        <.kv_rows
          rows={@data.workflow.rows}
          keys={[:sequence, :event_type, :node_name, :component_type]}
        />
      </.panel>
    </div>
    """
  end

  defp managed_view(assigns) do
    ~H"""
    <.panel title="Managed Workflows" data={@data}>
      <.kv_rows
        rows={@data.rows}
        keys={[:workflow_key, :workflow_name, :status, :restart_policy, :last_run_id]}
      />
      <.pager data={@data} action={:managed} />
    </.panel>
    """
  end

  defp scorecards_view(assigns) do
    ~H"""
    <.panel title="Scorecards And Evals" data={@data}>
      <.kv_rows rows={@data.rows} keys={[:run_id, :component_id, :objective_status, :created_at]} />
      <.pager data={@data} action={:scorecards} />
    </.panel>
    """
  end

  defp context_view(assigns) do
    ~H"""
    <div class="grid grid-cols-[minmax(0,1.1fr)_minmax(320px,.9fr)] gap-4 max-[1150px]:grid-cols-1">
      <div class="grid gap-4">
        <.panel
          title="Source Cues"
          data={
            %{
              rows: @data.source_cues,
              total: length(@data.source_cues),
              limit: @data.filters.limit,
              page: 1
            }
          }
        >
          <div :if={@data.source_cues == []} class="text-sm text-rune-muted">
            No source cues for this run.
          </div>
          <ul class="grid gap-2">
            <li
              :for={cue <- @data.source_cues}
              class="rounded-[12px] border border-rune-text/10 bg-black/25 p-3 text-sm text-rune-text-soft"
            >
              {cue}
            </li>
          </ul>
        </.panel>
        <.panel
          title="Messages"
          data={
            %{
              rows: @data.messages,
              total: length(@data.messages),
              limit: @data.filters.limit,
              page: 1
            }
          }
        >
          <.kv_rows rows={@data.messages} keys={[:role, :message_kind, :source_step, :content]} />
        </.panel>
      </div>
      <div class="grid content-start gap-4">
        <.panel
          title="Artifacts"
          data={
            %{
              rows: @data.artifacts,
              total: length(@data.artifacts),
              limit: @data.filters.limit,
              page: 1
            }
          }
        >
          <.kv_rows rows={@data.artifacts} keys={[:kind, :action, :path, :byte_size]} />
        </.panel>
        <.panel
          title="Facts"
          data={%{rows: @data.facts, total: length(@data.facts), limit: @data.filters.limit, page: 1}}
        >
          <.kv_rows rows={@data.facts} keys={[:producer_node, :component_id, :hash_key]} />
        </.panel>
      </div>
    </div>
    """
  end

  defp health_view(assigns) do
    ~H"""
    <.panel
      title="System Health"
      data={
        %{
          rows: Map.to_list(@data.counts || %{}),
          total: map_size(@data.counts || %{}),
          limit: 20,
          page: 1
        }
      }
    >
      <dl class="grid grid-cols-[180px_1fr] gap-x-4 gap-y-3 font-mono text-[11px] text-rune-text-soft">
        <dt class="text-rune-muted">runtime</dt>
        <dd>online</dd>
        <dt class="text-rune-muted">sqlite</dt>
        <dd>{if @data[:database], do: "wal synced", else: "memory"}</dd>
        <dt class="text-rune-muted">database</dt>
        <dd class="truncate">{@data[:database] || ":memory:"}</dd>
        <dt class="text-rune-muted">bind</dt>
        <dd>127.0.0.1</dd>
        <div :for={{key, value} <- @data.counts || %{}} class="contents">
          <dt class="text-rune-muted">{key}</dt>
          <dd>{value}</dd>
        </div>
      </dl>
    </.panel>
    """
  end

  attr :title, :string, required: true
  attr :data, :map, required: true
  slot :actions
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section class="runic-frost min-w-0 rounded-[18px] border border-rune-text/10 bg-black/25 p-4">
      <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-sm font-semibold text-rune-text">{@title}</h2>
          <p class="mt-1 font-mono text-[10.5px] text-rune-muted">
            showing {shown(@data)} of {@data[:total] || length(@data[:rows] || [])} rows,
            limit {@data[:limit] || @data[:filters][:limit] || 40}
          </p>
        </div>
        {render_slot(@actions)}
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  defp event_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full min-w-[760px] border-separate border-spacing-y-1 text-left">
        <thead class="font-mono text-[10px] uppercase text-rune-muted">
          <tr>
            <th class="px-2 py-1">Seq</th>
            <th class="px-2 py-1">Kind</th>
            <th class="px-2 py-1">Status</th>
            <th class="px-2 py-1">Phase</th>
            <th class="px-2 py-1">Title</th>
            <th class="px-2 py-1">Raw JSON</th>
          </tr>
        </thead>
        <tbody class="font-mono text-[11px] text-rune-text-soft">
          <tr :for={row <- @rows} class="bg-black/20">
            <td class="rounded-l-[10px] px-2 py-2 text-rune-muted">{row.sequence}</td>
            <td class="px-2 py-2">{row.kind}</td>
            <td class="px-2 py-2">{row.status}</td>
            <td class="px-2 py-2">{row.phase}</td>
            <td class="max-w-[320px] truncate px-2 py-2 text-rune-text">{row.title}</td>
            <td class="rounded-r-[10px] px-2 py-2">
              <details>
                <summary class="cursor-pointer text-rune-gold">preview</summary>
                <pre class="mt-2 max-h-56 overflow-auto rounded-[10px] bg-black/35 p-3 text-[10px] leading-5">{json_preview(row)}</pre>
              </details>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp kv_rows(assigns) do
    ~H"""
    <div :if={@rows == []} class="text-sm text-rune-muted">No rows match the current filters.</div>
    <div class="grid gap-2">
      <article
        :for={row <- @rows}
        class="min-w-0 rounded-[12px] border border-rune-text/10 bg-black/20 p-3"
      >
        <dl class="grid grid-cols-[128px_1fr] gap-x-3 gap-y-1 font-mono text-[10.5px] text-rune-text-soft">
          <div :for={key <- @keys} class="contents">
            <dt class="text-rune-muted">{key}</dt>
            <dd class="truncate">{value(row, key)}</dd>
          </div>
        </dl>
      </article>
    </div>
    """
  end

  defp pager(assigns) do
    ~H"""
    <div class="mt-4 flex flex-wrap items-center justify-between gap-3 font-mono text-[10.5px] text-rune-muted">
      <span>page {@data.page}</span>
      <div class="flex items-center gap-2">
        <.link
          patch={debug_path(@action, page_params(@data.filters, @data.page - 1))}
          class="inline-flex min-h-[30px] items-center gap-1 rounded-[9px] border border-rune-text/10 bg-black/20 px-2 text-rune-text-soft"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Prev
        </.link>
        <.link
          patch={debug_path(@action, page_params(@data.filters, @data.page + 1))}
          class="inline-flex min-h-[30px] items-center gap-1 rounded-[9px] border border-rune-text/10 bg-black/20 px-2 text-rune-text-soft"
        >
          Next <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      </div>
    </div>
    """
  end

  defp export_link(assigns) do
    ~H"""
    <.link
      :if={@filters[:run_id]}
      href={~p"/debug/export/#{@filters[:run_id]}"}
      class="inline-flex min-h-[32px] items-center gap-2 rounded-[10px] border border-rune-gold/25 bg-rune-gold/10 px-3 py-1.5 text-xs font-semibold text-rune-gold"
    >
      <.icon name="hero-arrow-down-tray" class="size-4" /> JSONL
    </.link>
    """
  end

  defp page_title(:logs), do: "Debug Logs"
  defp page_title(:traces), do: "Traces And Events"
  defp page_title(:managed), do: "Managed Workflows"
  defp page_title(:scorecards), do: "Scorecards And Evals"
  defp page_title(:context), do: "Context Inspector"
  defp page_title(:health), do: "System Health"

  defp debug_path(action, params) do
    query =
      params
      |> Enum.reject(fn {_key, value} -> blank?(value) end)
      |> URI.encode_query()

    path =
      case action do
        :logs -> "/debug/logs"
        :traces -> "/debug/traces"
        :managed -> "/debug/managed"
        :scorecards -> "/debug/scorecards"
        :context -> "/debug/context"
        :health -> "/debug/health"
        _other -> "/debug/logs"
      end

    if query == "", do: path, else: path <> "?" <> query
  end

  defp filter_params(filters) when is_map(filters) do
    filters
    |> Map.take([:run_id, :session_id, :kind, :status, :phase, :q, :limit])
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp page_params(filters, page) do
    filter_params(filters) ++ [{"page", max(page, 1)}]
  end

  defp shown(%{rows: rows}), do: length(rows)
  defp shown(%{terminal: %{rows: rows}}), do: length(rows)
  defp shown(_data), do: 0

  defp json_preview(row) do
    row
    |> Jason.encode!(pretty: true)
    |> String.slice(0, 4_000)
  end

  defp value(row, key) do
    row
    |> Map.get(key)
    |> case do
      nil -> "-"
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      value when is_atom(value) -> Atom.to_string(value)
      %DateTime{} = value -> DateTime.to_iso8601(value)
      %NaiveDateTime{} = value -> NaiveDateTime.to_iso8601(value)
      value -> inspect(value, limit: 8, printable_limit: 120)
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
