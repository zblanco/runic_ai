defmodule RunicAIWeb.WorkbenchLive do
  @moduledoc false

  use RunicAIWeb, :live_view

  alias RunicAI.Workbench
  alias RunicAIWeb.Markdown

  @debug_kinds ["events", "tool_calls", "messages", "runs"]
  @debug_modes ["compact", "expanded"]
  @workspace_tabs ["chat", "plan", "reviews"]
  @inspector_tabs ["trace", "logs", "artifacts", "details"]
  @session_filters ["all", "active", "review", "failed", "completed", "pinned"]
  @workbench_refresh_debounce_ms 75

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Workbench.subscribe()

    socket =
      socket
      |> assign(:page_title, "Local Agent Workbench")
      |> assign(:debug_kinds, @debug_kinds)
      |> assign(:debug_kind, "events")
      |> assign(:debug_mode, "compact")
      |> assign(:workspace_tab, "chat")
      |> assign(:inspector_tab, "trace")
      |> assign(:session_filter, "all")
      |> assign(:saved_filters, saved_filter_defs())
      |> assign(:session_filter_counts, %{})
      |> assign(:all_session_count, 0)
      |> assign(:sessions, [])
      |> assign(:selected_session_id, nil)
      |> assign(:snapshot, empty_snapshot())
      |> assign(:command_palette_open?, false)
      |> assign(:pinned_session_ids, MapSet.new())
      |> assign(:bookmarked_artifact_ids, MapSet.new())
      |> assign(:selected_artifact_id, nil)
      |> assign(:comparison_session_ids, [])
      |> assign(:contrast_mode, "normal")
      |> assign(:motion_mode, "full")
      |> assign(:workbench_refresh_timer, nil)
      |> assign(:workbench_refresh_active?, false)
      |> assign(:workbench_refresh_dirty?, false)
      |> assign(:workbench_refresh_session_id, nil)
      |> assign(:workbench_refresh_generation, 0)
      |> assign(:subscribed_session_id, nil)
      |> assign(:new_run_form, to_form(launch_defaults(), as: :run))
      |> assign(:health, Workbench.health())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :session_filter, normalize_session_filter(Map.get(params, "filter")))

    case socket.assigns.live_action do
      :index ->
        {:noreply,
         socket
         |> assign(:page_title, "RunicAI")
         |> assign(:selected_session_id, nil)
         |> assign(:snapshot, empty_snapshot())}

      action ->
        requested_session_id =
          case action do
            :new ->
              nil

            :reviews ->
              Workbench.first_pending_review_session_id() || Map.get(params, "session_id")

            _action ->
              Map.get(params, "session_id")
          end

        {:noreply, load_workbench(socket, requested_session_id)}
    end
  end

  @impl true
  def handle_event("submit_objective", %{"run" => params}, socket) do
    case Workbench.start_agent_run(params) do
      {:ok, %{session_id: session_id}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Run started")
         |> push_navigate(to: ~p"/sessions/#{session_id}")}

      {:error, :empty_objective} ->
        {:noreply, put_flash(socket, :error, "Objective is required")}

      {:error, {:invalid_cwd, cwd}} ->
        {:noreply, put_flash(socket, :error, "Workspace does not exist: #{cwd}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start run: #{inspect(reason)}")}
    end
  end

  def handle_event("review_decision", %{"review" => params}, socket) do
    session_id = socket.assigns.selected_session_id
    review_id = Map.get(params, "id")

    with true <- is_binary(session_id),
         true <- is_binary(review_id),
         {:ok, _event} <- Workbench.record_review_decision(session_id, review_id, params) do
      {:noreply,
       socket
       |> put_flash(:info, "Review decision recorded")
       |> load_workbench(session_id)}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Select a reviewable session first")}

      {:error, :empty_rewrite} ->
        {:noreply, put_flash(socket, :error, "Rewrite instruction is required")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not record review decision: #{inspect(reason)}")}
    end
  end

  def handle_event("set_debug_kind", %{"kind" => kind}, socket) when kind in @debug_kinds do
    {:noreply, assign(socket, :debug_kind, kind)}
  end

  def handle_event("set_debug_kind", _params, socket), do: {:noreply, socket}

  def handle_event("set_debug_mode", %{"mode" => mode}, socket) when mode in @debug_modes do
    {:noreply, assign(socket, :debug_mode, mode)}
  end

  def handle_event("set_debug_mode", _params, socket), do: {:noreply, socket}

  def handle_event("set_workspace_tab", %{"tab" => tab}, socket) when tab in @workspace_tabs do
    {:noreply, assign(socket, :workspace_tab, tab)}
  end

  def handle_event("set_workspace_tab", _params, socket), do: {:noreply, socket}

  def handle_event("set_inspector_tab", %{"tab" => tab}, socket) when tab in @inspector_tabs do
    {:noreply, assign(socket, :inspector_tab, tab)}
  end

  def handle_event("set_inspector_tab", _params, socket), do: {:noreply, socket}

  def handle_event("set_session_filter", %{"filter" => filter}, socket) do
    filter = normalize_session_filter(filter)
    {:noreply, push_patch(socket, to: filter_path(socket, filter))}
  end

  def handle_event("toggle_command_palette", _params, socket) do
    {:noreply, update(socket, :command_palette_open?, &(!&1))}
  end

  def handle_event("close_command_palette", _params, socket) do
    {:noreply, assign(socket, :command_palette_open?, false)}
  end

  def handle_event("run_command", %{"action" => action}, socket) do
    {:noreply, run_command(socket, action)}
  end

  def handle_event(
        "toggle_session_pin",
        _params,
        %{assigns: %{selected_session_id: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("toggle_session_pin", _params, socket) do
    session_id = socket.assigns.selected_session_id

    socket =
      socket
      |> update(:pinned_session_ids, &toggle_id(&1, session_id))
      |> load_workbench(session_id)

    {:noreply, socket}
  end

  def handle_event("toggle_artifact_bookmark", %{"artifact-id" => artifact_id}, socket) do
    {:noreply, update(socket, :bookmarked_artifact_ids, &toggle_id(&1, artifact_id))}
  end

  def handle_event("select_artifact", %{"artifact-id" => artifact_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_artifact_id, artifact_id)
     |> assign(:inspector_tab, "artifacts")}
  end

  def handle_event(
        "toggle_compare_session",
        _params,
        %{assigns: %{selected_session_id: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("toggle_compare_session", _params, socket) do
    session_id = socket.assigns.selected_session_id
    {:noreply, update(socket, :comparison_session_ids, &toggle_comparison_id(&1, session_id))}
  end

  def handle_event("toggle_contrast", _params, socket) do
    {:noreply, update(socket, :contrast_mode, &toggle_mode(&1, "normal", "high"))}
  end

  def handle_event("toggle_motion", _params, socket) do
    {:noreply, update(socket, :motion_mode, &toggle_mode(&1, "full", "reduced"))}
  end

  def handle_event("restore_preferences", params, socket) do
    pinned = params |> Map.get("pinned_session_ids", []) |> normalize_id_set()
    bookmarked = params |> Map.get("bookmarked_artifact_ids", []) |> normalize_id_set()
    contrast = normalize_mode(Map.get(params, "contrast_mode"), ["normal", "high"], "normal")
    motion = normalize_mode(Map.get(params, "motion_mode"), ["full", "reduced"], "full")

    socket =
      socket
      |> assign(:pinned_session_ids, pinned)
      |> assign(:bookmarked_artifact_ids, bookmarked)
      |> assign(:contrast_mode, contrast)
      |> assign(:motion_mode, motion)
      |> load_workbench(socket.assigns[:selected_session_id])

    {:noreply, socket}
  end

  @impl true
  def handle_info({:workbench, :terminal_event, event}, socket) do
    if socket.assigns.live_action == :index do
      {:noreply, socket}
    else
      selected_session_id = socket.assigns[:selected_session_id]

      socket =
        if is_nil(selected_session_id) or event.session_id == selected_session_id do
          request_workbench_refresh(socket, selected_session_id || event.session_id)
        else
          request_workbench_refresh(socket, selected_session_id)
        end

      {:noreply, socket}
    end
  end

  def handle_info(:refresh_workbench, socket) do
    socket = assign(socket, :workbench_refresh_timer, nil)

    socket =
      if socket.assigns[:workbench_refresh_active?] do
        assign(socket, :workbench_refresh_dirty?, true)
      else
        start_workbench_refresh(socket, socket.assigns[:workbench_refresh_session_id])
      end

    {:noreply, socket}
  end

  @impl true
  def handle_async({:workbench_refresh, generation}, {:ok, {generation, assigns}}, socket) do
    if generation == socket.assigns[:workbench_refresh_generation] do
      socket =
        socket
        |> assign(assigns)
        |> assign(:workbench_refresh_active?, false)
        |> maybe_subscribe_selected_session()

      socket =
        if socket.assigns[:workbench_refresh_dirty?] do
          start_workbench_refresh(socket, socket.assigns[:workbench_refresh_session_id])
        else
          assign(socket, :workbench_refresh_dirty?, false)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:workbench_refresh, generation}, {:exit, reason}, socket) do
    socket =
      if generation == socket.assigns[:workbench_refresh_generation] do
        socket
        |> assign(:workbench_refresh_active?, false)
        |> assign(:workbench_refresh_dirty?, false)
        |> put_flash(:error, "Could not refresh workbench: #{inspect(reason)}")
      else
        socket
      end

    {:noreply, socket}
  end

  defp load_workbench(socket, requested_session_id) do
    generation = (socket.assigns[:workbench_refresh_generation] || 0) + 1

    assigns =
      workbench_assigns(
        requested_session_id,
        socket.assigns.live_action,
        socket.assigns[:session_filter] || "all",
        socket.assigns[:pinned_session_ids] || MapSet.new()
      )

    socket
    |> assign(assigns)
    |> assign(:workbench_refresh_generation, generation)
    |> assign(:workbench_refresh_active?, false)
    |> assign(:workbench_refresh_dirty?, false)
    |> assign(:workbench_refresh_session_id, requested_session_id)
    |> maybe_subscribe_selected_session()
  end

  defp request_workbench_refresh(socket, requested_session_id) do
    socket =
      assign(
        socket,
        :workbench_refresh_session_id,
        requested_session_id || socket.assigns[:selected_session_id]
      )

    cond do
      socket.assigns[:workbench_refresh_active?] ->
        assign(socket, :workbench_refresh_dirty?, true)

      is_reference(socket.assigns[:workbench_refresh_timer]) ->
        socket

      true ->
        timer = Process.send_after(self(), :refresh_workbench, @workbench_refresh_debounce_ms)
        assign(socket, :workbench_refresh_timer, timer)
    end
  end

  defp start_workbench_refresh(socket, requested_session_id) do
    generation = socket.assigns[:workbench_refresh_generation] + 1
    live_action = socket.assigns.live_action
    filter = socket.assigns[:session_filter] || "all"
    pinned_session_ids = socket.assigns[:pinned_session_ids] || MapSet.new()

    socket
    |> assign(:workbench_refresh_generation, generation)
    |> assign(:workbench_refresh_active?, true)
    |> assign(:workbench_refresh_dirty?, false)
    |> start_async({:workbench_refresh, generation}, fn ->
      {generation,
       workbench_assigns(requested_session_id, live_action, filter, pinned_session_ids)}
    end)
  end

  defp workbench_assigns(requested_session_id, live_action, filter, pinned_session_ids) do
    all_sessions = Workbench.recent_sessions(limit: 40)
    sessions = filter_sessions(all_sessions, filter, pinned_session_ids)

    selected_session_id =
      cond do
        live_action == :new -> nil
        is_binary(requested_session_id) -> requested_session_id
        true -> first_session_id(sessions)
      end

    snapshot = load_snapshot(selected_session_id)

    %{
      all_session_count: length(all_sessions),
      sessions: sessions,
      session_filter_counts: session_filter_counts(all_sessions, pinned_session_ids),
      selected_session_id: selected_session_id,
      snapshot: snapshot
    }
  end

  defp maybe_subscribe_selected_session(socket) do
    selected_session_id = socket.assigns[:selected_session_id]

    if connected?(socket) and is_binary(selected_session_id) and
         socket.assigns[:subscribed_session_id] != selected_session_id do
      _ = Workbench.subscribe_session(selected_session_id)
      assign(socket, :subscribed_session_id, selected_session_id)
    else
      socket
    end
  end

  defp load_snapshot(nil), do: empty_snapshot()

  defp load_snapshot(session_id) do
    session_id
    |> Workbench.session_snapshot()
    |> case do
      nil -> empty_snapshot()
      snapshot -> decorate_snapshot(snapshot)
    end
  end

  defp decorate_snapshot(snapshot) do
    messages =
      Enum.map(snapshot.messages, fn message ->
        Map.put(message, :html, Markdown.to_html(message.content))
      end)

    %{snapshot | messages: messages}
  end

  defp empty_snapshot do
    %{
      session: nil,
      messages: [],
      events: [],
      tool_calls: [],
      runs: [],
      review_requests: [],
      artifacts: [],
      scorecards: [],
      metrics: %{
        messages: 0,
        events: 0,
        tool_calls: 0,
        runs: 0,
        review_requests: 0,
        artifacts: 0,
        scorecards: 0
      }
    }
  end

  defp launch_defaults do
    cfg = Workbench.config()

    %{
      "objective" => "",
      "agent" => cfg |> Keyword.get(:default_agent, :assistant) |> Atom.to_string(),
      "cwd" => File.cwd!(),
      "model" => Keyword.get(cfg, :default_model) || "",
      "client" => Keyword.get(cfg, :default_client) || "",
      "approve" => cfg |> Keyword.get(:default_approval, :safe) |> Atom.to_string(),
      "mode" => cfg |> Keyword.get(:default_mode, :verify) |> mode_value(),
      "session_id" => nil
    }
  end

  defp first_session_id([%{id: id} | _]), do: id
  defp first_session_id(_sessions), do: nil

  defp mode_value(:read_only), do: "read_only"
  defp mode_value(mode), do: Atom.to_string(mode)

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <a
      href="#run-objective"
      class="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:rounded-xl focus:bg-rune-bg focus:px-3 focus:py-2 focus:text-sm focus:text-rune-gold"
    >
      Skip to composer
    </a>

    <main class="runic-workbench grid min-h-screen place-items-center overflow-hidden px-4 py-8 text-rune-text">
      <section class="grid w-full max-w-[760px] place-items-center gap-10">
        <h1 class="sr-only">RunicAI</h1>
        <img
          src={~p"/images/runic-tome-logo.png"}
          alt="RunicAI"
          class="object-contain drop-shadow-[0_28px_70px_rgba(0,0,0,0.46)]"
        />

        <.form
          id="landing-run-form"
          for={@new_run_form}
          phx-submit="submit_objective"
          class="runic-composer-shell runic-frost grid w-full grid-cols-[1fr_auto] items-end gap-3 rounded-3xl p-3 shadow-[0_22px_70px_rgba(0,0,0,0.34)] max-[700px]:grid-cols-1"
        >
          <textarea
            id="run-objective"
            name={@new_run_form[:objective].name}
            class="min-h-[78px] max-h-[180px] w-full resize-y rounded-3xl border-0 bg-transparent px-5 py-4 text-base leading-7 text-rune-text outline-none placeholder:text-rune-muted"
            placeholder="Ask RunicAI to research, explain, inspect, plan, or make a local change..."
            autofocus
          >{Phoenix.HTML.Form.input_value(@new_run_form, :objective)}</textarea>
          <button
            type="submit"
            class="inline-flex min-h-[50px] items-center justify-center gap-2 rounded-2xl border border-rune-gold/25 bg-[linear-gradient(180deg,rgba(64,43,116,0.34),rgba(17,11,38,0.78))] px-5 py-3 text-sm font-semibold text-rune-gold shadow-[inset_0_1px_0_rgba(255,244,211,0.08),0_14px_34px_rgba(8,4,24,0.46)] hover:border-rune-gold/50"
          >
            <.icon name="hero-arrow-up" class="size-4" />
            <span>Run</span>
          </button>
          <input
            type="hidden"
            name={@new_run_form[:agent].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :agent)}
          />
          <input
            type="hidden"
            name={@new_run_form[:mode].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :mode)}
          />
          <input
            type="hidden"
            name={@new_run_form[:approve].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :approve)}
          />
          <input
            type="hidden"
            name={@new_run_form[:cwd].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :cwd)}
          />
          <input
            type="hidden"
            name={@new_run_form[:model].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :model)}
          />
          <input
            type="hidden"
            name={@new_run_form[:client].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :client)}
          />
        </.form>
      </section>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <a
      href="#run-objective"
      class="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:rounded-xl focus:bg-rune-bg focus:px-3 focus:py-2 focus:text-sm focus:text-rune-gold"
    >
      Skip to composer
    </a>

    <main
      id="runic-workbench"
      phx-hook="WorkbenchPreferences"
      data-pinned-session-ids={ids_json(@pinned_session_ids)}
      data-bookmarked-artifact-ids={ids_json(@bookmarked_artifact_ids)}
      data-contrast={@contrast_mode}
      data-motion={@motion_mode}
      class="runic-workbench min-h-screen overflow-hidden text-rune-text"
    >
      <div class="relative z-[1] grid h-screen grid-cols-[304px_minmax(680px,1fr)_410px] gap-[18px] p-[18px] max-[1240px]:grid-cols-[264px_minmax(520px,1fr)] max-[880px]:block max-[880px]:h-auto max-[880px]:min-h-screen max-[880px]:p-3">
        <aside class="runic-sidebar-panel runic-frost flex min-h-0 flex-col overflow-hidden rounded-[24px] max-[880px]:hidden">
          <.link
            navigate={~p"/"}
            aria-label="RunicAI home"
            class="grid grid-cols-[58px_1fr] items-center gap-3 px-[22px] pb-[18px] pt-[22px] hover:bg-rune-text/[0.025]"
          >
            <div class="grid size-[64px] place-items-center rounded-full border border-rune-gold/20 bg-rune-bg-deep/45 p-1 shadow-[inset_0_1px_0_rgba(255,244,211,0.14),0_18px_34px_rgba(0,0,0,0.28)]">
              <img
                src={~p"/images/runic-tome-logo.png"}
                alt="RunicAI"
                class="size-full object-contain bg-rune-surface/50"
              />
            </div>
            <div class="min-w-0">
              <h1 class="m-0 font-display text-2xl font-semibold leading-none text-rune-text">
                RunicAI
              </h1>
              <p class="mt-1 font-mono text-[11px] uppercase text-rune-muted">
                Agent workbench
              </p>
            </div>
          </.link>

          <div class="runic-scrollbar min-h-0 flex-1 overflow-y-auto px-3.5 pb-[22px] pt-4">
            <div class="mx-2.5 mb-2.5 mt-5 flex items-center justify-between gap-3 font-mono text-[11px] font-semibold uppercase text-rune-muted">
              <span>Workspace</span>
              <span class="truncate text-rune-gold">{display_path(active_workspace(@snapshot))}</span>
            </div>
            <nav class="-mx-3.5">
              <.sidebar_nav active icon="hero-command-line" label="Session Workbench" />
              <.sidebar_nav icon="hero-archive-box" label="Runs & Artifacts" />
              <.sidebar_nav icon="hero-cpu-chip" label="Agents" navigate={~p"/agents"} />
              <.sidebar_nav icon="hero-bars-3-bottom-left" label="Logs & Traces" />
              <.sidebar_nav icon="hero-cog-6-tooth" label="Local Settings" />
            </nav>

            <div class="mx-2.5 mb-2.5 mt-7 flex items-center justify-between gap-3 font-mono text-[11px] font-semibold uppercase text-rune-muted">
              <span>Recent sessions</span>
              <span class="inline-flex items-center gap-2">
                <.link
                  patch={~p"/sessions/new"}
                  title="New session"
                  aria-label="New session"
                  class="grid size-7 place-items-center rounded-[10px] border border-rune-gold/20 bg-rune-gold/10 text-rune-gold hover:border-rune-gold/45 hover:bg-rune-gold/15"
                >
                  <.icon name="hero-plus" class="size-4" />
                </.link>
                <span class="text-rune-gold">{length(@sessions)}</span>
              </span>
            </div>
            <div :if={@sessions == []} class="px-2 py-6 text-sm text-rune-muted">
              No sessions yet.
            </div>
            <.link
              :for={session <- @sessions}
              patch={~p"/sessions/#{session.id}"}
              class={session_link_class(session, @selected_session_id)}
            >
              <span class="mt-1 grid gap-1">
                <span class={["size-[9px] shrink-0 rounded-full", status_dot_class(session.status)]} />
                <.icon
                  :if={pinned?(@pinned_session_ids, session.id)}
                  name="hero-bookmark-solid"
                  class="size-3 text-rune-gold"
                />
              </span>
              <span class="min-w-0">
                <span class="block truncate text-[13px] font-semibold leading-snug text-rune-text">
                  {session.title}
                </span>
                <span class="mt-1.5 flex min-w-0 gap-2 truncate font-mono text-[10.5px] text-rune-muted">
                  <span>{session.agent}</span>
                  <span>{session.status}</span>
                </span>
              </span>
              <span class="font-mono text-[10px] text-rune-muted">
                {relative_time(session.started_at)}
              </span>
            </.link>

            <div class="mx-2.5 mb-2.5 mt-7 font-mono text-[11px] font-semibold uppercase text-rune-muted">
              Saved views
            </div>
            <nav class="-mx-3.5" aria-label="Saved session filters">
              <.filter_nav
                :for={filter <- @saved_filters}
                filter={filter}
                current={@session_filter}
                count={Map.get(@session_filter_counts, filter.id, 0)}
              />
            </nav>
          </div>

          <div class="grid gap-2.5 bg-black/10 px-[22px] py-4 font-mono text-[11px] text-rune-muted">
            <.health_row label="runtime" value="online" />
            <.health_row label="sqlite" value={sqlite_health(@health)} />
            <.health_row label="local bind" value="127.0.0.1" />
          </div>
        </aside>

        <section class="grid min-h-0 grid-rows-[auto_1fr_auto] max-[880px]:min-h-screen">
          <header class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-6 pb-[18px] pt-2 max-[880px]:grid-cols-1">
            <div class="min-w-0">
              <p class="mb-1 font-mono text-[11px] font-bold uppercase text-rune-primary">
                Session {selected_short_id(@snapshot)} - {session_state_label(@snapshot)}
              </p>
              <h2 class="truncate font-display text-[25px] font-semibold leading-[1.08] text-rune-text">
                {selected_title(@snapshot)}
              </h2>
            </div>
            <div class="flex flex-wrap items-center justify-end gap-2">
              <button
                id="command-palette-button"
                type="button"
                phx-click="toggle_command_palette"
                aria-keyshortcuts="Meta+K Control+K"
                class="inline-flex min-h-[30px] items-center gap-1.5 rounded-full border border-rune-gold/20 bg-rune-gold/10 px-2.5 py-1.5 font-mono text-[11px] text-rune-gold hover:border-rune-gold/45"
              >
                <.icon name="hero-command-line" class="size-3.5" />
                <span>Command palette</span>
              </button>
              <button
                :if={@selected_session_id}
                type="button"
                phx-click="toggle_session_pin"
                aria-pressed={pinned?(@pinned_session_ids, @selected_session_id)}
                class={[
                  "inline-flex min-h-[30px] items-center gap-1.5 rounded-full border px-2.5 py-1.5 font-mono text-[11px]",
                  pinned?(@pinned_session_ids, @selected_session_id) &&
                    "border-rune-gold/35 bg-rune-gold/15 text-rune-gold",
                  !pinned?(@pinned_session_ids, @selected_session_id) &&
                    "border-rune-text/5 bg-black/20 text-rune-text-soft hover:border-rune-gold/35"
                ]}
              >
                <.icon name="hero-bookmark" class="size-3.5" />
                <span>
                  {if pinned?(@pinned_session_ids, @selected_session_id), do: "Pinned", else: "Pin"}
                </span>
              </button>
              <button
                :if={@selected_session_id}
                type="button"
                phx-click="toggle_compare_session"
                aria-pressed={@selected_session_id in @comparison_session_ids}
                class="inline-flex min-h-[30px] items-center gap-1.5 rounded-full border border-rune-text/5 bg-black/20 px-2.5 py-1.5 font-mono text-[11px] text-rune-text-soft hover:border-rune-primary/35"
              >
                <.icon name="hero-arrows-right-left" class="size-3.5 text-rune-primary" />
                <span>Compare</span>
              </button>
              <button
                type="button"
                phx-click="toggle_contrast"
                aria-pressed={@contrast_mode == "high"}
                class="grid min-h-[30px] min-w-[30px] place-items-center rounded-full border border-rune-text/5 bg-black/20 text-rune-text-soft hover:border-rune-primary/35"
                title="Toggle high contrast"
              >
                <.icon name="hero-eye" class="size-3.5" />
              </button>
              <button
                type="button"
                phx-click="toggle_motion"
                aria-pressed={@motion_mode == "reduced"}
                class="grid min-h-[30px] min-w-[30px] place-items-center rounded-full border border-rune-text/5 bg-black/20 text-rune-text-soft hover:border-rune-primary/35"
                title="Toggle reduced motion"
              >
                <.icon name="hero-forward" class="size-3.5" />
              </button>
              <span class={[
                "inline-flex min-h-[30px] items-center gap-2 rounded-full border border-rune-text/5 px-2.5 py-1.5 font-mono text-[11px]",
                status_badge_class(selected_status(@snapshot))
              ]}>
                {selected_agent(@snapshot)} - {selected_status(@snapshot)}
              </span>
              <span
                :if={selected_model(@snapshot)}
                class="inline-flex min-h-[30px] items-center rounded-full border border-rune-text/5 bg-black/20 px-2.5 py-1.5 font-mono text-[11px] text-rune-text-soft"
              >
                model {selected_model(@snapshot)}
              </span>
              <span class="inline-flex min-h-[30px] items-center rounded-full border border-rune-text/5 bg-rune-gold/10 px-2.5 py-1.5 font-mono text-[11px] text-rune-gold">
                sqlite source of truth
              </span>
              <span class="inline-flex min-h-[30px] items-center rounded-full border border-rune-text/5 bg-black/20 px-2.5 py-1.5 font-mono text-[11px] text-rune-text-soft">
                {@debug_mode} debug
              </span>
            </div>
          </header>

          <section class="runic-scrollbar min-h-0 overflow-y-auto pb-5">
            <div class="grid gap-3">
              <div class="inline-flex max-w-full items-center gap-1.5 overflow-x-auto rounded-[14px] border border-rune-text/5 bg-black/20 p-1 shadow-[inset_0_1px_0_rgba(255,244,211,0.035)] runic-frost">
                <button
                  type="button"
                  phx-click="set_workspace_tab"
                  phx-value-tab="chat"
                  class={workspace_tab_class(@workspace_tab, "chat")}
                  aria-selected={@workspace_tab == "chat"}
                >
                  <.icon name="hero-chat-bubble-left-right" class="size-3.5 text-rune-gold" />
                  <span>Chat</span>
                  <span class="rounded-full border border-rune-text/5 bg-black/25 px-2 py-1 text-[10px] text-rune-primary">
                    {@snapshot.metrics.messages} messages
                  </span>
                </button>
                <button
                  type="button"
                  phx-click="set_workspace_tab"
                  phx-value-tab="plan"
                  class={workspace_tab_class(@workspace_tab, "plan")}
                  aria-selected={@workspace_tab == "plan"}
                >
                  <.icon name="hero-map" class="size-3.5 text-rune-gold" />
                  <span>Plan</span>
                  <span class="rounded-full border border-rune-text/5 bg-black/25 px-2 py-1 text-[10px] text-rune-muted">
                    {plan_state(@snapshot)}
                  </span>
                </button>
                <button
                  type="button"
                  phx-click="set_workspace_tab"
                  phx-value-tab="reviews"
                  class={workspace_tab_class(@workspace_tab, "reviews")}
                  aria-selected={@workspace_tab == "reviews"}
                >
                  <.icon name="hero-shield-check" class="size-3.5 text-rune-gold" />
                  <span>Reviews</span>
                  <span class="rounded-full border border-rune-text/5 bg-black/25 px-2 py-1 text-[10px] text-rune-muted">
                    {pending_review_count(@snapshot)}
                  </span>
                </button>
              </div>

              <section :if={@workspace_tab == "chat"} role="tabpanel">
                <% activity_cards = activity_cards(@snapshot) %>
                <% pending_review = pending_review(@snapshot) %>
                <% review_event =
                  review_event(@snapshot) ||
                    (pending_review && review_event_from_request(pending_review)) %>
                <% last_message_id = last_message_id(@snapshot.messages) %>
                <div
                  id="message-scroll"
                  phx-hook="WorkbenchScroll"
                  class="runic-chat-panel runic-frost overflow-hidden rounded-[18px]"
                >
                  <article :if={@snapshot.messages == []} class="border-b border-rune-text/10">
                    <div class="px-[18px] py-5">
                      <div class="mb-2 flex items-center justify-between gap-3 font-mono text-[11px] text-rune-muted">
                        <span class="inline-flex items-center gap-2">
                          <span class="grid size-6 place-items-center rounded-lg bg-rune-text/10 font-display text-sm text-rune-gold">
                            R
                          </span>
                          <strong class="text-rune-text-soft">RunicAI assistant</strong>
                        </span>
                        <span>ready - objective</span>
                      </div>
                      <p class="text-base leading-7 text-rune-text">
                        Start a local assistant run from the composer below.
                      </p>
                    </div>
                  </article>

                  <article
                    :for={message <- @snapshot.messages}
                    id={message.id}
                    class="border-b border-rune-text/10 last:border-b-0"
                  >
                    <div class="px-[18px] pb-5 pt-4">
                      <div class="mb-3 flex items-center justify-between gap-3 font-mono text-[11px] text-rune-muted">
                        <span class="inline-flex min-w-0 items-center gap-2">
                          <span class="grid size-6 shrink-0 place-items-center rounded-lg bg-rune-text/10 font-display text-sm leading-none text-rune-gold shadow-[inset_0_1px_0_rgba(255,244,211,0.075)]">
                            {message_avatar(message.role)}
                          </span>
                          <strong class="truncate text-rune-text-soft">
                            {message_sender(message.role)}
                          </strong>
                        </span>
                        <span class="shrink-0">
                          {format_time(message.created_at)} - {message.kind}
                        </span>
                      </div>
                      <div
                        class={[
                          "runic-markdown text-sm leading-6 text-rune-text-soft",
                          message.role == "user" && "text-base leading-7 text-rune-text"
                        ]}
                        phx-no-format
                      >{message.html}</div>
                      <div
                        :if={blocked_draft?(message)}
                        class="mt-4 rounded-xl border border-rune-gold/30 bg-rune-gold/10 px-3.5 py-3 text-xs leading-5 text-rune-text-soft"
                      >
                        <div class="mb-1 flex items-center gap-2 font-mono text-[10px] uppercase text-rune-gold">
                          <.icon name="hero-exclamation-triangle" class="size-3.5" />
                          <span>blocked draft</span>
                        </div>
                        <p>{blocking_reason(message)}</p>
                      </div>

                      <div
                        :if={message.id == last_message_id and activity_cards != []}
                        class="mt-4 grid grid-cols-3 gap-3 max-[880px]:grid-cols-1"
                      >
                        <.activity_card :for={activity <- activity_cards} activity={activity} />
                      </div>

                      <.review_card
                        :if={message.id == last_message_id and pending_review}
                        event={review_event}
                        review={pending_review}
                      />
                    </div>
                  </article>
                </div>
              </section>

              <section :if={@workspace_tab == "plan"} role="tabpanel">
                <div class="grid grid-cols-4 gap-3.5 max-[1240px]:grid-cols-2 max-[880px]:grid-cols-1">
                  <.plan_step :for={step <- plan_steps(@snapshot)} step={step} />
                </div>
              </section>

              <section :if={@workspace_tab == "reviews"} role="tabpanel">
                <div class="grid gap-3">
                  <.review_card
                    :for={review <- @snapshot.review_requests}
                    event={review_event(@snapshot) || review_event_from_request(review)}
                    review={review}
                  />
                  <div
                    :if={@snapshot.review_requests == []}
                    class="rounded-[18px] border border-rune-text/10 bg-black/20 px-5 py-8 text-sm text-rune-muted runic-frost"
                  >
                    No review requests for this session.
                  </div>
                </div>
              </section>
            </div>
          </section>

          <footer class="bg-[linear-gradient(0deg,rgba(10,7,14,0.56),transparent)] pt-0 runic-frost">
            <.form
              for={@new_run_form}
              phx-submit="submit_objective"
              class="runic-composer-shell runic-frost grid grid-cols-[1fr_auto] gap-4 rounded-3xl p-3 max-[880px]:grid-cols-1"
            >
              <textarea
                id="run-objective"
                name={@new_run_form[:objective].name}
                class="min-h-[62px] max-h-[130px] w-full px-4 py-2 resize-y border-0 bg-transparent text-sm leading-6 text-rune-text outline-none placeholder:text-rune-muted rounded-3xl"
                placeholder="Ask RunicAI to continue, inspect an event, approve with constraints, or launch a new local objective..."
              >{Phoenix.HTML.Form.input_value(@new_run_form, :objective)}</textarea>
              <div class="grid min-w-[180px] gap-2.5">
                <div class="grid grid-cols-2 gap-2">
                  <select
                    name={@new_run_form[:agent].name}
                    class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 text-center font-mono text-[11px] text-rune-text-soft"
                  >
                    <option
                      value="assistant"
                      selected={Phoenix.HTML.Form.input_value(@new_run_form, :agent) == "assistant"}
                    >
                      assistant
                    </option>
                    <option
                      value="standard"
                      selected={Phoenix.HTML.Form.input_value(@new_run_form, :agent) == "standard"}
                    >
                      standard
                    </option>
                    <option
                      value="rlm"
                      selected={Phoenix.HTML.Form.input_value(@new_run_form, :agent) == "rlm"}
                    >
                      rlm
                    </option>
                  </select>
                  <select
                    name={@new_run_form[:mode].name}
                    class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 text-center font-mono text-[11px] text-rune-text-soft"
                  >
                    <option
                      value="verify"
                      selected={Phoenix.HTML.Form.input_value(@new_run_form, :mode) == "verify"}
                    >
                      verify
                    </option>
                    <option
                      value="patch"
                      selected={Phoenix.HTML.Form.input_value(@new_run_form, :mode) == "patch"}
                    >
                      patch
                    </option>
                    <option
                      value="read_only"
                      selected={Phoenix.HTML.Form.input_value(@new_run_form, :mode) == "read_only"}
                    >
                      read only
                    </option>
                  </select>
                </div>
                <select
                  name={@new_run_form[:approve].name}
                  class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 text-center font-mono text-[11px] text-rune-text-soft"
                >
                  <option
                    value="safe"
                    selected={Phoenix.HTML.Form.input_value(@new_run_form, :approve) == "safe"}
                  >
                    approval: safe
                  </option>
                  <option
                    value="ask"
                    selected={Phoenix.HTML.Form.input_value(@new_run_form, :approve) == "ask"}
                  >
                    approval: ask
                  </option>
                  <option
                    value="never"
                    selected={Phoenix.HTML.Form.input_value(@new_run_form, :approve) == "never"}
                  >
                    approval: never
                  </option>
                </select>
                <details class="rounded-[11px] border border-rune-text/5 bg-black/20 px-3 py-2 text-[11px] leading-5 text-rune-text-soft">
                  <summary class="cursor-pointer font-mono text-[10px] uppercase tracking-[0.08em] text-rune-muted">
                    Run setup
                  </summary>
                  <div class="mt-2 grid gap-2">
                    <p>
                      <strong class="text-rune-text">assistant</strong>: structured/source-grounded workflows
                    </p>
                    <p>
                      <strong class="text-rune-text">standard</strong>: direct conversational/local runs
                    </p>
                    <p>
                      <strong class="text-rune-text">rlm</strong>: coding/RLM scorecard workflows
                    </p>
                    <p>
                      <strong class="text-rune-text">verify</strong>: inspect/analyze, <strong class="text-rune-text">patch</strong>: may propose file changes, <strong class="text-rune-text">read only</strong>: no writes expected
                    </p>
                    <p>
                      <strong class="text-rune-text">safe</strong>: approve low-risk actions, <strong class="text-rune-text">ask</strong>: pause in browser, <strong class="text-rune-text">never</strong>: deny gated actions
                    </p>
                  </div>
                </details>
                <button
                  type="submit"
                  class="inline-flex min-h-[38px] items-center justify-center gap-2 rounded-[11px] border border-rune-gold/25 bg-[linear-gradient(180deg,rgba(64,43,116,0.34),rgba(17,11,38,0.78))] px-3 py-2 text-sm font-semibold text-rune-gold shadow-[inset_0_1px_0_rgba(255,244,211,0.08),0_14px_34px_rgba(8,4,24,0.46)] hover:border-rune-gold/50"
                >
                  <.icon name="hero-arrow-turn-down-left" class="size-4" /> Send
                </button>
              </div>
              <input
                :if={@selected_session_id}
                type="hidden"
                name={@new_run_form[:session_id].name}
                value={@selected_session_id}
              />
              <input
                type="hidden"
                name={@new_run_form[:cwd].name}
                value={Phoenix.HTML.Form.input_value(@new_run_form, :cwd)}
              />
              <input
                type="hidden"
                name={@new_run_form[:model].name}
                value={Phoenix.HTML.Form.input_value(@new_run_form, :model)}
              />
              <input
                type="hidden"
                name={@new_run_form[:client].name}
                value={Phoenix.HTML.Form.input_value(@new_run_form, :client)}
              />
            </.form>
          </footer>
        </section>

        <aside class="runic-inspector-panel runic-frost grid min-h-0 grid-rows-[auto_auto_1fr] overflow-hidden rounded-[24px] max-[1240px]:hidden">
          <div class="grid grid-cols-[1fr_auto] items-start gap-3 px-[22px] pb-3 pt-[22px]">
            <div class="min-w-0">
              <h2 class="m-0 font-display text-[22px] font-semibold text-rune-text">Inspector</h2>
              <span class="sr-only">Debug records</span>
              <span class="sr-only">Events</span>
              <p class="mt-1.5 truncate font-mono text-[11px] text-rune-muted">
                selected: {inspector_context(@snapshot)}
              </p>
            </div>
            <button
              type="button"
              title="Inspector collapse is coming next"
              class="grid size-[34px] place-items-center rounded-xl bg-rune-text/10 text-rune-text-soft shadow-[inset_0_1px_0_rgba(255,244,211,0.075)]"
            >
              <.icon name="hero-chevron-right" class="size-4" />
            </button>
          </div>

          <div class="mx-3.5 mb-4 flex items-center gap-1 rounded-[14px] border border-rune-text/5 bg-black/25 p-1 shadow-[inset_0_1px_0_rgba(255,244,211,0.035)]">
            <.inspector_tab
              current={@inspector_tab}
              tab="trace"
              icon="hero-bars-3-bottom-left"
              label="Trace"
            />
            <.inspector_tab current={@inspector_tab} tab="logs" icon="hero-table-cells" label="Logs" />
            <.inspector_tab
              current={@inspector_tab}
              tab="artifacts"
              icon="hero-archive-box"
              label="Artifacts"
            />
            <.inspector_tab
              current={@inspector_tab}
              tab="details"
              icon="hero-identification"
              label="Details"
            />
          </div>

          <div class="runic-scrollbar min-h-0 overflow-y-auto">
            <section :if={@inspector_tab == "trace"} class="pb-4">
              <div :if={@snapshot.events == []} class="px-[22px] py-8 text-sm text-rune-muted">
                No trace events.
              </div>
              <.trace_record :for={event <- Enum.take(@snapshot.events, 40)} event={event} />
            </section>

            <section :if={@inspector_tab == "logs"} class="px-[18px] pb-[18px] pt-1">
              <div class="mb-3 flex items-center justify-between gap-3">
                <div>
                  <div class="font-mono text-[11px] font-bold uppercase text-rune-muted">
                    Debug records
                  </div>
                  <div class="mt-1 font-mono text-[10.5px] text-rune-muted">
                    Events
                  </div>
                </div>
                <div class="flex items-center gap-1">
                  <button
                    type="button"
                    phx-click="set_debug_mode"
                    phx-value-mode="compact"
                    class={debug_mode_class(@debug_mode, "compact")}
                    title="Compact debug"
                  >
                    <.icon name="hero-bars-3-bottom-left" class="size-4" />
                  </button>
                  <button
                    type="button"
                    phx-click="set_debug_mode"
                    phx-value-mode="expanded"
                    class={debug_mode_class(@debug_mode, "expanded")}
                    title="Expanded debug"
                  >
                    <.icon name="hero-list-bullet" class="size-4" />
                  </button>
                  <form phx-change="set_debug_kind">
                    <select
                      name="kind"
                      class="rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft"
                    >
                      <option :for={kind <- @debug_kinds} value={kind} selected={kind == @debug_kind}>
                        {debug_label(kind)}
                      </option>
                    </select>
                  </form>
                </div>
              </div>

              <% table = debug_table(@snapshot, @debug_kind, @debug_mode) %>
              <div class="runic-scrollbar overflow-auto rounded-[14px] border border-rune-text/5 bg-black/15">
                <table class="w-full table-fixed border-collapse text-left font-mono text-[10.5px]">
                  <thead class="text-rune-muted">
                    <tr>
                      <th
                        :for={header <- table.headers}
                        class="border-b border-rune-text/10 px-2 py-2 font-bold uppercase"
                      >
                        {header}
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- table.rows} class="border-b border-rune-text/5 last:border-b-0">
                      <td :for={cell <- row.cells} class="truncate px-2 py-2 text-rune-text-soft">
                        {cell}
                      </td>
                    </tr>
                    <tr :if={table.rows == []}>
                      <td
                        colspan={length(table.headers)}
                        class="px-2 py-6 text-center text-rune-muted"
                      >
                        No records.
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section :if={@inspector_tab == "artifacts"} class="px-[18px] pb-[18px] pt-1">
              <% selected_artifact = selected_artifact(@snapshot, @selected_artifact_id) %>
              <.diff_artifact_panel
                :if={selected_artifact}
                artifact={selected_artifact}
                bookmarked?={bookmarked?(@bookmarked_artifact_ids, selected_artifact.id)}
              />
              <.artifact_record
                :for={artifact <- Enum.take(@snapshot.artifacts, 8)}
                title={artifact.title}
                meta={artifact.kind || artifact.action || "artifact"}
                tone={artifact.action}
                detail={artifact.preview || artifact.path || artifact.sha256}
                select_id={artifact.id}
                bookmark_id={artifact.id}
                bookmarked?={bookmarked?(@bookmarked_artifact_ids, artifact.id)}
              />
              <.artifact_record
                :for={tool <- Enum.take(@snapshot.tool_calls, 6)}
                title={tool.tool_name}
                meta={tool.status}
                tone={tool.status}
                detail={json_preview(tool.args)}
              />
              <.artifact_record
                :for={scorecard <- Enum.take(@snapshot.scorecards, 4)}
                title="Verification summary"
                meta={scorecard.objective_status}
                tone={scorecard.objective_status}
                detail={scorecard_summary(scorecard)}
              />
              <.artifact_record
                :for={run <- Enum.take(@snapshot.runs, 6)}
                title={run.workflow_name || run.workflow_key || run.id}
                meta={run.status}
                tone={run.status}
                detail={run.trigger || "workflow run"}
                href={~p"/runs/#{run.id}/graph"}
              />
              <div
                :if={
                  @snapshot.artifacts == [] and @snapshot.tool_calls == [] and @snapshot.runs == [] and
                    @snapshot.scorecards == []
                }
                class="py-8 text-sm text-rune-muted"
              >
                No artifacts or tool records.
              </div>
            </section>

            <section :if={@inspector_tab == "details"} class="px-[18px] pb-[18px] pt-1">
              <.comparison_panel sessions={
                comparison_sessions(@snapshot, @sessions, @comparison_session_ids)
              } />
              <div class="rounded-[17px] bg-rune-text/[0.04] p-[15px] shadow-[inset_0_1px_0_rgba(255,244,211,0.06)]">
                <div class="mb-2 flex items-center justify-between gap-2 font-mono text-[10.5px] text-rune-muted">
                  <span>session</span>
                  <span class="rounded-full bg-rune-success/15 px-2 py-1 text-rune-success">
                    local
                  </span>
                </div>
                <h3 class="mb-3 text-[13px] font-semibold text-rune-text">Session details</h3>
                <dl class="grid grid-cols-[118px_1fr] gap-x-3 gap-y-2 font-mono text-[10.5px] text-rune-text-soft">
                  <dt class="text-rune-muted">workspace</dt>
                  <dd class="truncate">{display_path(active_workspace(@snapshot))}</dd>
                  <dt class="text-rune-muted">agent</dt>
                  <dd>{selected_agent(@snapshot)}</dd>
                  <dt class="text-rune-muted">model</dt>
                  <dd class="truncate">{selected_model(@snapshot) || "-"}</dd>
                  <dt class="text-rune-muted">approval</dt>
                  <dd>{selected_approval(@snapshot) || "-"}</dd>
                  <dt class="text-rune-muted">database</dt>
                  <dd class="truncate">{Path.basename(to_string(@health.database || "memory"))}</dd>
                  <dt class="text-rune-muted">messages</dt>
                  <dd>{@snapshot.metrics.messages}</dd>
                  <dt class="text-rune-muted">events</dt>
                  <dd>{@snapshot.metrics.events}</dd>
                </dl>
              </div>
            </section>
          </div>
        </aside>
      </div>
    </main>

    <.command_palette
      open?={@command_palette_open?}
      commands={command_entries(@snapshot, @session_filter, @contrast_mode, @motion_mode)}
    />
    """
  end

  attr :active, :boolean, default: false
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :navigate, :string, default: nil

  defp sidebar_nav(assigns) do
    ~H"""
    <.link
      :if={@navigate}
      navigate={@navigate}
      class={[
        "relative flex w-full items-center gap-2.5 px-[26px] py-[11px] text-left text-rune-text-soft hover:bg-rune-text/[0.035] hover:text-rune-text",
        @active &&
          "bg-[linear-gradient(90deg,rgba(222,166,81,0.09),rgba(255,244,211,0.028)_44%,transparent)] text-rune-text before:absolute before:bottom-0 before:left-0 before:top-0 before:w-[3px] before:bg-rune-gold"
      ]}
    >
      <.icon name={@icon} class="size-[18px] text-rune-gold" />
      <span>{@label}</span>
    </.link>
    <button
      :if={!@navigate}
      type="button"
      class={[
        "relative flex w-full items-center gap-2.5 px-[26px] py-[11px] text-left text-[13px] text-rune-text-soft hover:bg-rune-text/[0.035] hover:text-rune-text",
        @active &&
          "bg-[linear-gradient(90deg,rgba(222,166,81,0.09),rgba(255,244,211,0.028)_44%,transparent)] text-rune-text before:absolute before:bottom-0 before:left-0 before:top-0 before:w-[3px] before:bg-rune-gold"
      ]}
    >
      <.icon name={@icon} class="size-[18px] text-rune-gold" />
      <span>{@label}</span>
    </button>
    """
  end

  attr :filter, :map, required: true
  attr :current, :string, required: true
  attr :count, :integer, default: 0

  defp filter_nav(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_session_filter"
      phx-value-filter={@filter.id}
      aria-pressed={@current == @filter.id}
      class={[
        "relative flex w-full items-center gap-2.5 px-[26px] py-[11px] text-left text-[13px] text-rune-text-soft hover:bg-rune-text/[0.035] hover:text-rune-text",
        @current == @filter.id &&
          "bg-[linear-gradient(90deg,rgba(222,166,81,0.09),rgba(255,244,211,0.028)_44%,transparent)] text-rune-text before:absolute before:bottom-0 before:left-0 before:top-0 before:w-[3px] before:bg-rune-gold"
      ]}
    >
      <.icon name={@filter.icon} class="size-[18px] text-rune-gold" />
      <span class="min-w-0 flex-1 truncate">{@filter.label}</span>
      <span class="rounded-full border border-rune-text/5 bg-black/20 px-2 py-0.5 font-mono text-[10px] text-rune-muted">
        {@count}
      </span>
    </button>
    """
  end

  attr :open?, :boolean, required: true
  attr :commands, :list, required: true

  defp command_palette(assigns) do
    ~H"""
    <div
      :if={@open?}
      id="command-palette"
      role="dialog"
      aria-modal="true"
      aria-label="Command palette"
      class="fixed inset-0 z-40 grid place-items-start bg-black/48 px-4 pt-[12vh] backdrop-blur-sm"
    >
      <button
        type="button"
        phx-click="close_command_palette"
        aria-label="Close command palette"
        class="absolute inset-0 cursor-default"
      >
      </button>
      <section class="runic-command-palette runic-frost relative z-[1] mx-auto w-full max-w-[680px] overflow-hidden rounded-[18px] border border-rune-gold/20 bg-rune-bg/95 shadow-[0_30px_120px_rgba(0,0,0,0.58)]">
        <div class="flex items-center gap-3 border-b border-rune-text/10 px-4 py-3">
          <.icon name="hero-command-line" class="size-5 text-rune-gold" />
          <div class="min-w-0 flex-1">
            <h2 class="text-sm font-semibold text-rune-text">Commands</h2>
            <p class="font-mono text-[11px] text-rune-muted">Operator actions</p>
          </div>
          <kbd class="rounded-lg border border-rune-text/10 bg-black/25 px-2 py-1 font-mono text-[10px] text-rune-muted">
            Esc
          </kbd>
        </div>
        <div class="runic-scrollbar max-h-[58vh] overflow-y-auto p-2">
          <button
            :for={command <- @commands}
            type="button"
            phx-click="run_command"
            phx-value-action={command.action}
            class="grid w-full grid-cols-[28px_1fr_auto] items-center gap-3 rounded-[12px] px-3 py-2.5 text-left hover:bg-rune-text/[0.055] focus:bg-rune-text/[0.075] focus:outline-none"
          >
            <span class="grid size-7 place-items-center rounded-lg bg-rune-text/10 text-rune-gold">
              <.icon name={command.icon} class="size-4" />
            </span>
            <span class="min-w-0">
              <span class="block truncate text-sm font-semibold text-rune-text">{command.label}</span>
              <span class="mt-0.5 block truncate font-mono text-[11px] text-rune-muted">
                {command.detail}
              </span>
            </span>
            <kbd
              :if={command[:shortcut]}
              class="rounded-lg border border-rune-text/10 bg-black/25 px-2 py-1 font-mono text-[10px] text-rune-muted"
            >
              {command.shortcut}
            </kbd>
          </button>
        </div>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp health_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <span>{@label}</span>
      <strong class="truncate font-semibold text-rune-success">{@value}</strong>
    </div>
    """
  end

  attr :activity, :map, required: true

  defp activity_card(assigns) do
    ~H"""
    <div class="min-h-[104px] rounded-[14px] border border-rune-text/5 bg-black/25 p-3.5 shadow-[inset_0_1px_0_rgba(255,244,211,0.035)]">
      <span class="font-mono text-[10.5px] uppercase text-rune-muted">{@activity.label}</span>
      <strong class="mt-1.5 block text-[13px] leading-snug text-rune-text">{@activity.title}</strong>
      <code class="mt-1.5 block truncate font-mono text-[11px] text-rune-gold">
        {@activity.detail}
      </code>
    </div>
    """
  end

  attr :event, :map, required: true
  attr :review, :map, default: nil

  defp review_card(assigns) do
    ~H"""
    <div class="runic-review-card mt-[18px] rounded-2xl">
      <h3 class="px-[18px] pt-4 text-[15px] font-semibold text-rune-text">Review required</h3>
      <p class="mx-[18px] mt-2 text-[13px] leading-6 text-rune-text-soft">
        <strong>Policy:</strong> {first_present(@event.title, "Runtime requested human approval.")}
      </p>
      <p class="mx-[18px] mt-2 text-[13px] leading-6 text-rune-text-soft">
        <strong>Context:</strong> {first_present(@event.detail, event_summary(@event))}
      </p>
      <.form
        :if={review_open?(@review)}
        id={"review-form-#{dom_id(@review.id)}"}
        for={%{}}
        as={:review}
        phx-submit="review_decision"
        class="grid gap-3 px-[18px] pb-[18px] pt-4"
      >
        <input type="hidden" name="review[id]" value={@review.id} />
        <textarea
          name="review[rewrite]"
          class="min-h-[58px] w-full resize-y rounded-[12px] border border-rune-text/5 bg-black/20 px-3 py-2 text-xs leading-5 text-rune-text outline-none placeholder:text-rune-muted"
          placeholder="Rewrite instruction..."
        ></textarea>
        <div class="flex flex-wrap gap-2">
          <button
            type="submit"
            name="review[action]"
            value="approve"
            class="min-h-[34px] rounded-[11px] border border-rune-primary/25 bg-rune-primary/20 px-3 py-2 text-xs font-semibold text-rune-primary-soft hover:border-rune-primary/45"
          >
            Approve once
          </button>
          <button
            type="submit"
            name="review[action]"
            value="rewrite"
            class="min-h-[34px] rounded-[11px] border border-rune-text/5 bg-black/25 px-3 py-2 text-xs font-semibold text-rune-text hover:border-rune-gold/35"
          >
            Rewrite instruction
          </button>
          <button
            type="submit"
            name="review[action]"
            value="deny"
            class="min-h-[34px] rounded-[11px] border border-rune-text/5 bg-black/25 px-3 py-2 text-xs font-semibold text-rune-warning hover:border-rune-warning/35"
          >
            Deny
          </button>
          <button
            type="submit"
            name="review[action]"
            value="stop"
            class="min-h-[34px] rounded-[11px] border border-rune-text/5 bg-black/25 px-3 py-2 text-xs font-semibold text-rune-text hover:border-rune-error/35"
          >
            Stop session
          </button>
        </div>
      </.form>
      <div
        :if={@review && !review_open?(@review)}
        class="mx-[18px] mb-[18px] mt-4 rounded-[12px] border border-rune-text/5 bg-black/20 px-3 py-2 font-mono text-[11px] text-rune-text-soft"
      >
        Decision: {review_decision_label(@review)}
      </div>
      <div :if={!@review} class="flex flex-wrap gap-2 px-[18px] pb-[18px] pt-4">
        <button
          type="button"
          disabled
          class="min-h-[34px] rounded-[11px] border border-rune-text/5 bg-rune-primary/20 px-3 py-2 text-xs font-semibold text-rune-primary-soft disabled:opacity-70"
        >
          Approve once
        </button>
        <button
          type="button"
          disabled
          class="min-h-[34px] rounded-[11px] border border-rune-text/5 bg-black/25 px-3 py-2 text-xs font-semibold text-rune-text disabled:opacity-70"
        >
          Rewrite instruction
        </button>
        <button
          type="button"
          disabled
          class="min-h-[34px] rounded-[11px] border border-rune-text/5 bg-black/25 px-3 py-2 text-xs font-semibold text-rune-warning disabled:opacity-70"
        >
          Deny
        </button>
        <button
          type="button"
          disabled
          class="min-h-[34px] rounded-[11px] border border-rune-text/5 bg-black/25 px-3 py-2 text-xs font-semibold text-rune-text disabled:opacity-70"
        >
          Stop session
        </button>
      </div>
    </div>
    """
  end

  attr :step, :map, required: true

  defp plan_step(assigns) do
    ~H"""
    <div class={plan_step_class(@step.state)}>
      <span class="block font-mono text-[10.5px] uppercase text-rune-muted">{@step.label}</span>
      <strong class="mt-1.5 block text-[13px] leading-snug text-rune-text">{@step.title}</strong>
      <em class="mt-1.5 block truncate font-mono text-[10.5px] not-italic text-rune-text-soft">
        {@step.detail}
      </em>
    </div>
    """
  end

  attr :current, :string, required: true
  attr :tab, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp inspector_tab(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_inspector_tab"
      phx-value-tab={@tab}
      class={inspector_tab_class(@current, @tab)}
    >
      <.icon name={@icon} class="size-3.5 text-rune-gold" />
      <span>{@label}</span>
    </button>
    """
  end

  attr :event, :map, required: true

  defp trace_record(assigns) do
    ~H"""
    <div class="border-t border-rune-text/5 px-[22px] py-[17px] first:border-t-0">
      <div class="mb-2 flex items-center justify-between gap-2 font-mono text-[10.5px] text-rune-muted">
        <span>{format_time(@event.at)}</span>
        <span class={["rounded-full px-2 py-1 uppercase", event_status_class(@event.status)]}>
          {@event.status}
        </span>
      </div>
      <h3 class="text-[13px] font-semibold leading-snug text-rune-text">
        {first_present(@event.title, event_summary(@event))}
      </h3>
      <p :if={@event.detail} class="mt-2 text-xs leading-5 text-rune-text-soft">
        {@event.detail}
      </p>
      <dl
        :if={@event.data != %{}}
        class="mt-2 grid grid-cols-[118px_1fr] gap-x-3 gap-y-1.5 font-mono text-[10.5px] text-rune-text-soft"
      >
        <dt class="text-rune-muted">kind</dt>
        <dd class="truncate">{@event.kind}</dd>
        <dt class="text-rune-muted">phase</dt>
        <dd class="truncate">{@event.phase || "-"}</dd>
        <dt class="text-rune-muted">run</dt>
        <dd class="truncate">{short(@event.run_id)}</dd>
      </dl>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :meta, :any, required: true
  attr :tone, :any, default: nil
  attr :detail, :string, default: nil
  attr :href, :string, default: nil
  attr :select_id, :string, default: nil
  attr :bookmark_id, :string, default: nil
  attr :bookmarked?, :boolean, default: false

  defp artifact_record(assigns) do
    ~H"""
    <div class="mb-3 rounded-[17px] bg-rune-text/[0.04] p-[15px] shadow-[inset_0_1px_0_rgba(255,244,211,0.06)]">
      <div class="mb-2 flex items-center justify-between gap-2 font-mono text-[10.5px] text-rune-muted">
        <span class="truncate">{@meta}</span>
        <span class={["rounded-full px-2 py-1 uppercase", event_status_class(@tone)]}>{@meta}</span>
      </div>
      <h3 class="text-[13px] font-semibold leading-snug text-rune-text">
        <.link :if={@href} patch={@href} class="hover:text-rune-gold">{@title}</.link>
        <span :if={!@href}>{@title}</span>
      </h3>
      <p :if={@detail} class="mt-2 line-clamp-3 text-xs leading-5 text-rune-text-soft">{@detail}</p>
      <div :if={@select_id || @bookmark_id} class="mt-3 flex flex-wrap gap-2">
        <button
          :if={@select_id}
          type="button"
          phx-click="select_artifact"
          phx-value-artifact-id={@select_id}
          class="inline-flex min-h-[30px] items-center gap-1.5 rounded-[10px] border border-rune-primary/20 bg-rune-primary/10 px-2.5 py-1.5 text-[11px] font-semibold text-rune-primary-soft hover:border-rune-primary/40"
        >
          <.icon name="hero-document-magnifying-glass" class="size-3.5" /> Diff
        </button>
        <button
          :if={@bookmark_id}
          type="button"
          phx-click="toggle_artifact_bookmark"
          phx-value-artifact-id={@bookmark_id}
          aria-pressed={@bookmarked?}
          class={[
            "inline-flex min-h-[30px] items-center gap-1.5 rounded-[10px] border px-2.5 py-1.5 text-[11px] font-semibold",
            @bookmarked? && "border-rune-gold/35 bg-rune-gold/15 text-rune-gold",
            !@bookmarked? &&
              "border-rune-text/5 bg-black/20 text-rune-text-soft hover:border-rune-gold/35"
          ]}
        >
          <.icon name="hero-bookmark" class="size-3.5" />
          {if @bookmarked?, do: "Bookmarked", else: "Bookmark"}
        </button>
      </div>
    </div>
    """
  end

  attr :artifact, :map, required: true
  attr :bookmarked?, :boolean, default: false

  defp diff_artifact_panel(assigns) do
    ~H"""
    <section class="mb-3 rounded-[17px] border border-rune-primary/20 bg-rune-primary/[0.055] p-[15px] shadow-[inset_0_1px_0_rgba(122,225,180,0.12)]">
      <div class="mb-3 flex items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="font-mono text-[10.5px] uppercase text-rune-primary">Diff artifact</p>
          <h3 class="mt-1 truncate text-[13px] font-semibold text-rune-text">
            {@artifact.title}
          </h3>
        </div>
        <span
          :if={@bookmarked?}
          class="rounded-full bg-rune-gold/15 px-2 py-1 font-mono text-[10px] uppercase text-rune-gold"
        >
          bookmarked
        </span>
      </div>
      <pre class="runic-diff-panel runic-scrollbar max-h-[260px] overflow-auto rounded-[12px] border border-rune-text/10 bg-black/35 p-3 font-mono text-[11px] leading-5"><code><span
            :for={line <- diff_lines(@artifact)}
            class={diff_line_class(line)}
          >{line}<br /></span></code></pre>
    </section>
    """
  end

  attr :sessions, :list, required: true

  defp comparison_panel(assigns) do
    ~H"""
    <section class="mb-3 rounded-[17px] border border-rune-purple/20 bg-rune-purple/[0.055] p-[15px] shadow-[inset_0_1px_0_rgba(187,132,232,0.11)]">
      <div class="mb-3 flex items-center justify-between gap-3">
        <div>
          <p class="font-mono text-[10.5px] uppercase text-rune-purple">Prompt/model comparison</p>
          <h3 class="mt-1 text-[13px] font-semibold text-rune-text">Comparison slots</h3>
        </div>
        <span class="rounded-full bg-black/25 px-2 py-1 font-mono text-[10px] text-rune-muted">
          {length(@sessions)} selected
        </span>
      </div>
      <div class="grid gap-2">
        <article
          :for={session <- @sessions}
          class="rounded-[12px] border border-rune-text/5 bg-black/20 p-3"
        >
          <div class="mb-1 flex items-center justify-between gap-2 font-mono text-[10.5px] text-rune-muted">
            <span class="truncate">{session.short_id || short(session.id)}</span>
            <span>{session.status}</span>
          </div>
          <strong class="block truncate text-xs text-rune-text">{session.title}</strong>
          <p class="mt-1 truncate font-mono text-[10.5px] text-rune-text-soft">
            {session.agent} - {session.model || "default model"}
          </p>
        </article>
        <p :if={@sessions == []} class="text-xs leading-5 text-rune-muted">No comparison slots.</p>
      </div>
    </section>
    """
  end

  defp saved_filter_defs do
    [
      %{id: "all", label: "All Sessions", icon: "hero-inbox-stack"},
      %{id: "active", label: "Active Runs", icon: "hero-bolt"},
      %{id: "review", label: "Needs Review", icon: "hero-exclamation-triangle"},
      %{id: "failed", label: "Failed Checks", icon: "hero-x-circle"},
      %{id: "completed", label: "Completed", icon: "hero-check-circle"},
      %{id: "pinned", label: "Pinned", icon: "hero-bookmark"}
    ]
  end

  defp command_entries(snapshot, session_filter, contrast_mode, motion_mode) do
    [
      %{
        action: "new_session",
        icon: "hero-plus",
        label: "New session",
        detail: selected_title(snapshot),
        shortcut: "G N"
      },
      %{
        action: "focus_composer",
        icon: "hero-pencil-square",
        label: "Focus composer",
        detail: selected_status(snapshot),
        shortcut: "/"
      },
      %{
        action: "reviews",
        icon: "hero-shield-check",
        label: "Review queue",
        detail: "#{pending_review_count(snapshot)} pending",
        shortcut: "G R"
      },
      %{
        action: "logs",
        icon: "hero-table-cells",
        label: "Logs and traces",
        detail: "#{snapshot.metrics.events} events",
        shortcut: "G L"
      },
      %{
        action: "agents",
        icon: "hero-cpu-chip",
        label: "Agents",
        detail: selected_agent(snapshot)
      },
      %{
        action: "filter_review",
        icon: "hero-exclamation-triangle",
        label: "Filter review sessions",
        detail: if(session_filter == "review", do: "active", else: "available")
      },
      %{
        action: "filter_pinned",
        icon: "hero-bookmark",
        label: "Filter pinned sessions",
        detail: if(session_filter == "pinned", do: "active", else: "available")
      },
      %{
        action: "expanded_debug",
        icon: "hero-list-bullet",
        label: "Expanded debug",
        detail: "inspector density"
      },
      %{
        action: "toggle_contrast",
        icon: "hero-eye",
        label: "High contrast",
        detail: contrast_mode
      },
      %{
        action: "toggle_motion",
        icon: "hero-forward",
        label: "Reduced motion",
        detail: motion_mode
      }
    ]
  end

  defp run_command(socket, "new_session") do
    socket
    |> assign(:command_palette_open?, false)
    |> push_patch(to: ~p"/sessions/new")
  end

  defp run_command(socket, "focus_composer") do
    socket
    |> assign(:command_palette_open?, false)
    |> push_event("focus-composer", %{})
  end

  defp run_command(socket, "reviews") do
    socket
    |> assign(:command_palette_open?, false)
    |> push_patch(to: ~p"/reviews")
  end

  defp run_command(socket, "logs") do
    socket
    |> assign(:command_palette_open?, false)
    |> push_navigate(to: ~p"/debug/logs")
  end

  defp run_command(socket, "agents") do
    socket
    |> assign(:command_palette_open?, false)
    |> push_navigate(to: ~p"/agents")
  end

  defp run_command(socket, "filter_review") do
    socket
    |> assign(:command_palette_open?, false)
    |> push_patch(to: filter_path(socket, "review"))
  end

  defp run_command(socket, "filter_pinned") do
    socket
    |> assign(:command_palette_open?, false)
    |> push_patch(to: filter_path(socket, "pinned"))
  end

  defp run_command(socket, "expanded_debug") do
    socket
    |> assign(:command_palette_open?, false)
    |> assign(:debug_mode, "expanded")
  end

  defp run_command(socket, "toggle_contrast") do
    socket
    |> assign(:command_palette_open?, false)
    |> update(:contrast_mode, &toggle_mode(&1, "normal", "high"))
  end

  defp run_command(socket, "toggle_motion") do
    socket
    |> assign(:command_palette_open?, false)
    |> update(:motion_mode, &toggle_mode(&1, "full", "reduced"))
  end

  defp run_command(socket, _action), do: assign(socket, :command_palette_open?, false)

  defp filter_sessions(sessions, "active", _pinned) do
    Enum.filter(sessions, &(&1.status in ["running", "waiting", "review"]))
  end

  defp filter_sessions(sessions, "review", _pinned) do
    Enum.filter(sessions, &(&1.status in ["waiting", "review", "blocked"]))
  end

  defp filter_sessions(sessions, "failed", _pinned) do
    Enum.filter(sessions, &(&1.status in ["failed", "error", "blocked"]))
  end

  defp filter_sessions(sessions, "completed", _pinned) do
    Enum.filter(sessions, &(&1.status in ["completed", "ok"]))
  end

  defp filter_sessions(sessions, "pinned", pinned) do
    Enum.filter(sessions, &MapSet.member?(pinned, &1.id))
  end

  defp filter_sessions(sessions, _filter, _pinned), do: sessions

  defp session_filter_counts(sessions, pinned) do
    Map.new(@session_filters, fn filter ->
      {filter, sessions |> filter_sessions(filter, pinned) |> length()}
    end)
  end

  defp normalize_session_filter(filter) when filter in @session_filters, do: filter
  defp normalize_session_filter(_filter), do: "all"

  defp filter_path(socket, filter) do
    base =
      case socket.assigns.live_action do
        :new -> ~p"/sessions/new"
        :reviews -> ~p"/reviews"
        :show -> ~p"/sessions/#{socket.assigns.selected_session_id}"
        _index -> ~p"/"
      end

    if filter == "all", do: base, else: base <> "?" <> URI.encode_query(%{"filter" => filter})
  end

  defp toggle_id(%MapSet{} = ids, id) when is_binary(id) do
    if MapSet.member?(ids, id), do: MapSet.delete(ids, id), else: MapSet.put(ids, id)
  end

  defp toggle_id(_ids, id), do: MapSet.new([id])

  defp toggle_comparison_id(ids, id) when is_binary(id) do
    ids =
      if id in ids do
        Enum.reject(ids, &(&1 == id))
      else
        [id | ids]
      end

    Enum.take(ids, 2)
  end

  defp toggle_comparison_id(ids, _id), do: ids

  defp toggle_mode(current, current, next), do: next
  defp toggle_mode(_current, current, _next), do: current

  defp normalize_id_set(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp normalize_id_set(_ids), do: MapSet.new()

  defp normalize_mode(value, allowed, default) do
    if value in allowed, do: value, else: default
  end

  defp ids_json(%MapSet{} = ids), do: ids |> MapSet.to_list() |> Jason.encode!()
  defp ids_json(_ids), do: "[]"

  defp pinned?(%MapSet{} = ids, id) when is_binary(id), do: MapSet.member?(ids, id)
  defp pinned?(_ids, _id), do: false

  defp bookmarked?(%MapSet{} = ids, id) when is_binary(id), do: MapSet.member?(ids, id)
  defp bookmarked?(_ids, _id), do: false

  defp selected_artifact(%{artifacts: artifacts}, id) when is_binary(id) do
    Enum.find(artifacts, &(&1.id == id)) || List.first(artifacts)
  end

  defp selected_artifact(%{artifacts: [artifact | _]}, _id), do: artifact
  defp selected_artifact(_snapshot, _id), do: nil

  defp diff_lines(artifact) do
    artifact
    |> artifact_diff_text()
    |> String.split("\n")
    |> case do
      [""] -> ["No diff preview available."]
      lines -> lines
    end
  end

  defp artifact_diff_text(artifact) do
    metadata = artifact.metadata || %{}
    payload = metadata["payload"] || metadata[:payload] || %{}

    value =
      first_present(
        metadata["diff"] || metadata[:diff] || metadata["patch"] || metadata[:patch] ||
          payload["diff"] || payload[:diff] || payload["patch"] || payload[:patch],
        artifact.preview || artifact.path || ""
      )

    to_string(value)
  end

  defp diff_line_class("+" <> _rest), do: "text-rune-success"
  defp diff_line_class("-" <> _rest), do: "text-rune-error"
  defp diff_line_class("@@" <> _rest), do: "text-rune-primary"
  defp diff_line_class(_line), do: "text-rune-text-soft"

  defp comparison_sessions(snapshot, sessions, ids) do
    selected =
      case snapshot do
        %{session: nil} -> []
        %{session: session} -> [session]
      end

    (selected ++ Enum.filter(sessions, &(&1.id in ids)))
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(2)
  end

  defp selected_title(%{session: %{title: title}}), do: title
  defp selected_title(_snapshot), do: "Local agent workbench"

  defp selected_status(%{session: %{status: status}}), do: status
  defp selected_status(_snapshot), do: "idle"

  defp selected_agent(%{session: %{agent: agent}}), do: agent
  defp selected_agent(_snapshot), do: "assistant"

  defp selected_model(%{session: %{model: model}}), do: model
  defp selected_model(_snapshot), do: nil

  defp selected_workspace(%{session: %{workspace_root: workspace}}) when is_binary(workspace),
    do: workspace

  defp selected_workspace(_snapshot), do: nil

  defp selected_approval(%{session: %{metadata: metadata}}) when is_map(metadata) do
    metadata["approval"] || metadata[:approval]
  end

  defp selected_approval(_snapshot), do: nil

  defp first_present(nil, fallback), do: fallback
  defp first_present("", fallback), do: fallback
  defp first_present(value, _fallback), do: value

  defp selected_short_id(%{session: %{short_id: short_id}}) when is_binary(short_id), do: short_id
  defp selected_short_id(%{session: %{id: id}}), do: short(id)
  defp selected_short_id(_snapshot), do: "new"

  defp session_state_label(snapshot) do
    case review_event(snapshot) do
      nil -> selected_status(snapshot)
      _event -> "approval required"
    end
  end

  defp active_workspace(snapshot) do
    selected_workspace(snapshot) || File.cwd!()
  end

  defp display_path(nil), do: "-"

  defp display_path(path) do
    path
    |> to_string()
    |> String.replace_prefix(System.user_home!(), "~")
  end

  defp sqlite_health(%{database: nil}), do: "memory"
  defp sqlite_health(%{database: database}) when is_binary(database), do: "wal synced"
  defp sqlite_health(_health), do: "ready"

  defp session_link_class(session, selected_session_id) do
    [
      "relative grid grid-cols-[12px_1fr_auto] items-start gap-3 px-[26px] py-3.5 text-left transition hover:bg-rune-text/[0.035]",
      session.id == selected_session_id &&
        "bg-[linear-gradient(90deg,rgba(122,225,180,0.105),rgba(255,244,211,0.026)_48%,transparent)] before:absolute before:bottom-0 before:left-0 before:top-0 before:w-[3px] before:bg-rune-primary",
      session.id != selected_session_id && "text-rune-text-soft"
    ]
  end

  defp workspace_tab_class(current, tab) do
    [
      "inline-flex min-h-[34px] items-center gap-2 whitespace-nowrap rounded-[10px] px-2.5 py-1.5 font-mono text-[11px]",
      current == tab &&
        "bg-rune-text/10 text-rune-text shadow-[inset_0_1px_0_rgba(255,244,211,0.07)]",
      current != tab && "text-rune-muted hover:bg-rune-text/[0.06] hover:text-rune-text"
    ]
  end

  defp inspector_tab_class(current, tab) do
    [
      "inline-flex min-h-[34px] flex-1 items-center justify-center gap-1.5 whitespace-nowrap rounded-[10px] px-2 py-1.5 font-mono text-[11px]",
      current == tab &&
        "bg-rune-text/10 text-rune-text shadow-[inset_0_1px_0_rgba(255,244,211,0.07)]",
      current != tab && "text-rune-muted hover:bg-rune-text/[0.06] hover:text-rune-text"
    ]
  end

  defp relative_time(nil), do: "-"

  defp relative_time(%DateTime{} = time) do
    seconds = DateTime.diff(DateTime.utc_now(), time, :second)

    cond do
      seconds < 60 -> "now"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> Calendar.strftime(time, "%m-%d")
    end
  end

  defp relative_time(_time), do: "-"

  defp plan_state(snapshot) do
    case pending_review(snapshot) do
      nil -> selected_status(snapshot)
      _review -> "waiting review"
    end
  end

  defp last_message_id([]), do: nil
  defp last_message_id(messages), do: messages |> List.last() |> Map.get(:id)

  defp message_avatar("user"), do: "D"
  defp message_avatar("assistant"), do: "R"
  defp message_avatar(_role), do: "*"

  defp message_sender("user"), do: "doops"
  defp message_sender("assistant"), do: "RunicAI assistant"
  defp message_sender(role), do: role || "system"

  defp blocked_draft?(message) when is_map(message) do
    message
    |> Map.get(:content_json, %{})
    |> json_field("blocked?", false)
    |> truthy?()
  end

  defp blocking_reason(message) when is_map(message) do
    message
    |> Map.get(:content_json, %{})
    |> json_field("blocking_reason", nil)
    |> case do
      reason when is_binary(reason) and reason != "" -> reason
      _other -> "This output is available, but the run still needs repair before it is complete."
    end
  end

  defp json_field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp json_field(_map, _key, default), do: default

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp activity_cards(snapshot) do
    [
      latest_message_card(snapshot),
      latest_event_card(snapshot),
      latest_tool_or_run_card(snapshot)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
  end

  defp latest_message_card(%{messages: []}), do: nil

  defp latest_message_card(%{messages: messages}) do
    message = List.last(messages)

    %{
      label: message.kind || "message",
      title: first_line(message.content),
      detail: message.source_step || message.workflow_node || message.role
    }
  end

  defp latest_event_card(%{events: []}), do: nil

  defp latest_event_card(%{events: events}) do
    event = List.first(events)

    %{
      label: event.kind || "trace",
      title: first_present(event.title, event_summary(event)),
      detail: event.phase || event.status || "event"
    }
  end

  defp latest_tool_or_run_card(%{tool_calls: [tool | _tools]}) do
    %{
      label: "tool",
      title: tool.tool_name || tool.tool_id || tool.id,
      detail: tool.status || "requested"
    }
  end

  defp latest_tool_or_run_card(%{runs: [run | _runs]}) do
    %{
      label: "workflow",
      title: run.workflow_name || run.workflow_key || run.id,
      detail: run.status || "running"
    }
  end

  defp latest_tool_or_run_card(_snapshot), do: nil

  defp review_event(%{events: events}) do
    Enum.find(events, fn event ->
      event.kind == "hitl" or
        event.phase in ["review_requested", "review", "approval_requested"] or
        event.status in ["review", "waiting"]
    end)
  end

  defp review_event(_snapshot), do: nil

  defp pending_review(%{review_requests: reviews}) do
    Enum.find(reviews, &(&1.status in ["pending", "waiting"]))
  end

  defp pending_review(_snapshot), do: nil

  defp pending_review_count(%{review_requests: reviews}) do
    Enum.count(reviews, &(&1.status in ["pending", "waiting"]))
  end

  defp pending_review_count(_snapshot), do: 0

  defp review_event_from_request(review) do
    %{
      title: review.kind || "Review request",
      detail: review_detail(review),
      kind: "hitl",
      phase: review.checkpoint,
      status: review.status
    }
  end

  defp plan_steps(snapshot) do
    metrics = snapshot.metrics
    review = review_event(snapshot)
    current_event = List.first(snapshot.events)

    [
      %{
        state: "done",
        label: "01 objective",
        title: selected_title(snapshot),
        detail: "accepted - #{format_time(selected_started_at(snapshot))}"
      },
      %{
        state: "done",
        label: "02 context",
        title: "Loaded persisted session projection.",
        detail: "#{metrics.messages} messages - #{metrics.events} events"
      },
      %{
        state: execution_state(snapshot),
        label: "03 execution",
        title: current_event_title(current_event),
        detail: selected_model(snapshot) || "streaming terminal events"
      },
      %{
        state: if(review, do: "wait", else: "done"),
        label: "04 review",
        title: review_title(review),
        detail: selected_approval(snapshot) || "policy: local"
      }
    ]
  end

  defp selected_started_at(%{session: %{started_at: started_at}}), do: started_at
  defp selected_started_at(_snapshot), do: nil

  defp execution_state(snapshot) do
    case selected_status(snapshot) do
      status when status in ["running", :running] -> "live"
      status when status in ["waiting", "review", :waiting, :review] -> "wait"
      status when status in ["failed", :failed] -> "error"
      _status -> "done"
    end
  end

  defp current_event_title(nil), do: "Waiting for the next persisted event."
  defp current_event_title(event), do: first_present(event.title, event_summary(event))

  defp review_title(nil), do: "No pending approval."
  defp review_title(event), do: first_present(event.title, "Awaiting approval.")

  defp plan_step_class("live") do
    plan_step_base() <>
      " before:bg-rune-primary before:shadow-[0_0_18px_rgba(122,225,180,0.5)]"
  end

  defp plan_step_class("wait"), do: plan_step_base() <> " before:bg-rune-warning"
  defp plan_step_class("error"), do: plan_step_base() <> " before:bg-rune-error"
  defp plan_step_class(_state), do: plan_step_base() <> " before:bg-rune-success"

  defp plan_step_base do
    "relative min-h-[88px] rounded-2xl border border-rune-text/10 bg-black/25 px-4 py-[15px] shadow-[inset_0_1px_0_rgba(255,244,211,0.035),0_12px_34px_rgba(0,0,0,0.18)] before:absolute before:bottom-[18px] before:left-0 before:top-[18px] before:w-[3px] before:rounded-full"
  end

  defp inspector_context(%{session: nil}), do: "new objective"

  defp inspector_context(snapshot) do
    case pending_review(snapshot) do
      nil -> "#{selected_status(snapshot)} - session #{selected_short_id(snapshot)}"
      _review -> "review gate - session #{selected_short_id(snapshot)}"
    end
  end

  defp event_summary(%{kind: kind, phase: phase}) do
    [kind, phase]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
    |> case do
      "" -> "event"
      summary -> summary
    end
  end

  defp event_summary(_event), do: "event"

  defp review_detail(%{details: details}) when is_map(details) and details != %{} do
    details
    |> Map.take(["path", "tool_name", "reason", "write_policy"])
    |> case do
      empty when empty == %{} -> json_preview(details)
      picked -> json_preview(picked)
    end
  end

  defp review_detail(review), do: review.resume_key || review.id

  defp review_open?(%{status: status}), do: status in ["pending", "waiting"]
  defp review_open?(_review), do: false

  defp review_decision_label(%{status: status, decision: decision}) when is_map(decision) do
    decision["decision"] || decision[:decision] || status || "resolved"
  end

  defp review_decision_label(%{status: status}), do: status || "resolved"

  defp scorecard_summary(%{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp scorecard_summary(scorecard) do
    checks = length(scorecard.acceptance_results || [])
    risks = length(scorecard.residual_risks || [])
    files = length(scorecard.changed_files || [])
    "#{checks} checks - #{risks} risks - #{files} files"
  end

  defp debug_mode_class(current, mode) do
    [
      "rounded-[10px] p-1.5",
      current == mode && "bg-rune-text/10 text-rune-text",
      current != mode && "text-rune-muted hover:bg-rune-text/10"
    ]
  end

  defp status_dot_class(status) when status in ["running", :running],
    do: "bg-rune-primary shadow-[0_0_20px_rgba(122,225,180,0.46)]"

  defp status_dot_class(status) when status in ["review", :review], do: "bg-rune-magenta"
  defp status_dot_class(status) when status in ["waiting", :waiting], do: "bg-rune-warning"
  defp status_dot_class(status) when status in ["failed", :failed], do: "bg-rune-error"
  defp status_dot_class(status) when status in ["completed", :completed], do: "bg-rune-success"
  defp status_dot_class(_status), do: "bg-rune-muted"

  defp status_badge_class(status) when status in ["running", :running],
    do: "bg-rune-primary/15 text-rune-primary"

  defp status_badge_class(status) when status in ["review", :review],
    do: "bg-rune-magenta/15 text-rune-magenta"

  defp status_badge_class(status) when status in ["waiting", :waiting],
    do: "bg-rune-warning/15 text-rune-warning"

  defp status_badge_class(status) when status in ["failed", :failed],
    do: "bg-rune-error/15 text-rune-error"

  defp status_badge_class(_status), do: "bg-rune-success/15 text-rune-success"

  defp event_status_class(status) when status in ["running", :running],
    do: "bg-rune-primary/15 text-rune-primary"

  defp event_status_class(status) when status in ["review", :review],
    do: "bg-rune-magenta/15 text-rune-magenta"

  defp event_status_class(status) when status in ["waiting", "blocked", :waiting, :blocked],
    do: "bg-rune-warning/15 text-rune-warning"

  defp event_status_class(status) when status in ["error", :error],
    do: "bg-rune-error/15 text-rune-error"

  defp event_status_class(_status), do: "bg-rune-success/15 text-rune-success"

  defp debug_label("tool_calls"), do: "Tool calls"
  defp debug_label("messages"), do: "Messages"
  defp debug_label("runs"), do: "Runs"
  defp debug_label(_kind), do: "Events"

  defp debug_table(snapshot, "tool_calls", mode) do
    headers =
      if mode == "expanded", do: ["id", "tool", "status", "args"], else: ["id", "tool", "status"]

    rows =
      Enum.map(snapshot.tool_calls, fn tool ->
        cells = [short(tool.id), tool.tool_name, tool.status]
        %{cells: maybe_debug_detail(cells, json_preview(tool.args), mode)}
      end)

    %{headers: headers, rows: rows}
  end

  defp debug_table(snapshot, "messages", mode) do
    headers =
      if mode == "expanded", do: ["id", "role", "kind", "preview"], else: ["id", "role", "kind"]

    rows =
      Enum.map(snapshot.messages, fn message ->
        cells = [short(message.id), message.role, message.kind]
        %{cells: maybe_debug_detail(cells, first_line(message.content), mode)}
      end)

    %{headers: headers, rows: rows}
  end

  defp debug_table(snapshot, "runs", mode) do
    headers =
      if mode == "expanded",
        do: ["id", "workflow", "status", "trigger"],
        else: ["id", "workflow", "status"]

    rows =
      Enum.map(snapshot.runs, fn run ->
        cells = [short(run.id), run.workflow_name || run.workflow_key, run.status]
        %{cells: maybe_debug_detail(cells, run.trigger, mode)}
      end)

    %{headers: headers, rows: rows}
  end

  defp debug_table(snapshot, _kind, mode) do
    headers =
      if mode == "expanded",
        do: ["seq", "kind", "status", "title"],
        else: ["seq", "kind", "status"]

    rows =
      Enum.map(snapshot.events, fn event ->
        cells = [pad_sequence(event.sequence), event.kind, event.status]
        %{cells: maybe_debug_detail(cells, event.title, mode)}
      end)

    %{headers: headers, rows: rows}
  end

  defp maybe_debug_detail(cells, _detail, "compact"), do: cells
  defp maybe_debug_detail(cells, detail, _mode), do: cells ++ [detail || "-"]

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = time) do
    Calendar.strftime(time, "%H:%M:%S")
  end

  defp format_time(_time), do: "-"

  defp pad_sequence(nil), do: "----"

  defp pad_sequence(sequence) when is_integer(sequence) do
    sequence
    |> Integer.to_string()
    |> String.pad_leading(4, "0")
  end

  defp short(nil), do: "-"

  defp short(value) do
    value
    |> to_string()
    |> String.split(":")
    |> List.last()
    |> String.slice(0, 12)
  end

  defp dom_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end

  defp first_line(nil), do: "-"

  defp first_line(value) do
    value
    |> to_string()
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 80)
  end

  defp json_preview(value) do
    value
    |> Jason.encode!()
    |> String.slice(0, 80)
  rescue
    _exception -> inspect(value, limit: 10)
  end
end
