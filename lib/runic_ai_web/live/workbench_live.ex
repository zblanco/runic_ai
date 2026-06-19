defmodule RunicAIWeb.WorkbenchLive do
  @moduledoc false

  use RunicAIWeb, :live_view

  import RunicAIWeb.GraphComponents

  alias RunicAI.Event
  alias RunicAI.LLM.ModelCatalog
  alias RunicAI.Workbench
  alias RunicAIWeb.Markdown

  @debug_kinds ["events", "tool_calls", "messages", "runs"]
  @debug_modes ["compact", "expanded"]
  @workspace_tabs ["chat", "plan", "reviews"]
  @inspector_tabs ["trace", "logs", "artifacts", "details"]
  @session_filters ["all", "active", "review", "failed", "completed", "pinned"]
  @session_sidebar_limit 16
  @workbench_refresh_debounce_ms 75
  @landing_agent_modes [
    %{
      id: "standard",
      label: "Standard",
      icon: "hero-command-line",
      meta: "coding agent",
      detail:
        "Direct local coding loop for repo inspection, shell-backed changes, and verification."
    },
    %{
      id: "assistant",
      label: "Assistant",
      icon: "hero-sparkles",
      meta: "workflow builder",
      detail:
        "General-purpose assistant for research, explanation, planning, and structured workflow runs."
    },
    %{
      id: "rlm",
      label: "Workflow RLM",
      icon: "hero-cpu-chip",
      meta: "patch mode",
      detail:
        "Objective-gated workflow coordination for local implementation with reviewable writes."
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Workbench.subscribe()

    model_catalog = ModelCatalog.catalog()
    health = Workbench.health()

    launch_defaults =
      model_catalog
      |> launch_defaults()
      |> put_default_sandbox_params(health)

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
      |> assign(:model_catalog, model_catalog)
      |> assign(:new_run_params, launch_defaults)
      |> assign(:new_run_form, to_form(launch_defaults, as: :run))
      |> assign(:health, health)

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

  def handle_event("change_run_form", %{"run" => params}, socket) do
    params = Map.merge(socket.assigns.new_run_params, params)
    {:noreply, put_new_run_form(socket, params)}
  end

  def handle_event("select_landing_agent", %{"agent" => agent}, socket) do
    params =
      socket.assigns.new_run_params
      |> Map.merge(landing_agent_launch_params(agent))

    {:noreply, put_new_run_form(socket, params)}
  end

  def handle_event("select_landing_sandbox", %{"sandbox" => sandbox_id}, socket) do
    case landing_sandbox_option(socket.assigns.health, sandbox_id) do
      %{selectable?: true} = sandbox ->
        params =
          socket.assigns.new_run_params
          |> Map.merge(landing_sandbox_launch_params(sandbox))

        {:noreply, put_new_run_form(socket, params)}

      _sandbox ->
        {:noreply, socket}
    end
  end

  def handle_event("select_model_provider", %{"run" => %{"model_provider" => provider}}, socket) do
    params =
      socket.assigns.new_run_params
      |> Map.put("model_provider", provider)
      |> Map.delete("model_id")
      |> Map.delete("model")

    {:noreply, put_new_run_form(socket, params)}
  end

  def handle_event("select_model_id", %{"run" => %{"model_id" => model_id}}, socket) do
    params =
      socket.assigns.new_run_params
      |> Map.put("model_id", model_id)

    {:noreply, put_new_run_form(socket, params)}
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

  def handle_event("approval_policy", %{"approval" => params}, socket) do
    session_id = socket.assigns.selected_session_id

    with true <- is_binary(session_id),
         {:ok, result} <- Workbench.record_approval_policy(session_id, params) do
      message =
        case result do
          %{policy: :always, approved_count: count} ->
            "Approval policy set to always; approved #{count} pending non-budget review(s)"

          %{policy: policy} ->
            "Approval policy set to #{policy}"
        end

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> load_workbench(session_id)}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Select a session first")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not update approval policy: #{inspect(reason)}")}
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
  def handle_info({:workbench, :event, %Event{} = event}, socket) do
    handle_workbench_event(socket, event.session_id)
  end

  def handle_info({:workbench, :terminal_event, _event}, socket) do
    {:noreply, socket}
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

  defp handle_workbench_event(socket, event_session_id) do
    if socket.assigns.live_action == :index do
      {:noreply, socket}
    else
      selected_session_id = socket.assigns[:selected_session_id]

      socket =
        if is_nil(selected_session_id) or event_session_id == selected_session_id do
          request_workbench_refresh(socket, selected_session_id || event_session_id)
        else
          request_workbench_refresh(socket, selected_session_id)
        end

      {:noreply, socket}
    end
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

    selected_session_changed? =
      assigns.selected_session_id != socket.assigns[:selected_session_id]

    socket
    |> assign(assigns)
    |> assign(:workbench_refresh_generation, generation)
    |> assign(:workbench_refresh_active?, false)
    |> assign(:workbench_refresh_dirty?, false)
    |> assign(:workbench_refresh_session_id, requested_session_id)
    |> maybe_put_session_run_form(assigns.snapshot, selected_session_changed?)
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
    all_sessions = Workbench.recent_session_summaries(limit: @session_sidebar_limit)
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
        content = message.content || ""

        message
        |> Map.put(:content, content)
        |> Map.put(:html, Markdown.to_html(content))
      end)

    %{snapshot | messages: messages}
  end

  defp empty_snapshot do
    %{
      session: nil,
      messages: [],
      events: [],
      sandbox_executions: [],
      child_repairs: [],
      tool_calls: [],
      runs: [],
      review_requests: [],
      artifacts: [],
      scorecards: [],
      capability_profile: nil,
      objective_loop: nil,
      objective_contract: nil,
      blocked_evidence: nil,
      plan_workflow_graph: nil,
      progress_summary: %{},
      metrics: %{
        messages: 0,
        events: 0,
        sandbox_executions: 0,
        child_repairs: 0,
        tool_calls: 0,
        runs: 0,
        review_requests: 0,
        artifacts: 0,
        scorecards: 0
      }
    }
  end

  defp launch_defaults(model_catalog) do
    cfg = Workbench.config()
    model = Keyword.get(cfg, :default_model) || model_catalog.default_model
    {provider, model_id} = model_selection_from_spec(model, model_catalog)

    %{
      "objective" => "",
      "agent" => cfg |> Keyword.get(:default_agent, :assistant) |> Atom.to_string(),
      "cwd" => File.cwd!(),
      "model_provider" => provider,
      "model_id" => model_id,
      "model" => "#{provider}:#{model_id}",
      "client" => Keyword.get(cfg, :default_client) || "",
      "approve" => cfg |> Keyword.get(:default_approval, :safe) |> Atom.to_string(),
      "mode" => cfg |> Keyword.get(:default_mode, :verify) |> mode_value(),
      "write_policy" =>
        cfg
        |> Keyword.get(
          :default_write_policy,
          default_write_policy(Keyword.get(cfg, :default_mode, :verify))
        )
        |> write_policy_value(),
      "profile" => cfg |> Keyword.get(:default_profile, :local_workbench) |> profile_value(),
      "toolsets" => "",
      "disabled_tools" => "",
      "tool_config" => "terminal.shell_review=always",
      "sandbox_profile" => "local_code",
      "sandbox_backend" => "just_bash",
      "sandbox_runtime" => "bash",
      "sandbox_runtimes" => "bash",
      "sandbox_network" => "disabled",
      "sandbox_stateful" => "false",
      "sandbox_pool_warm" => "0",
      "sandbox_pool_max" => "1",
      "session_id" => nil
    }
  end

  defp model_selection_from_spec(model, model_catalog) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        {provider, model_id}

      _other ->
        {model_catalog.default_provider, model_catalog.default_model_id}
    end
  end

  defp model_selection_from_spec(_model, model_catalog),
    do: {model_catalog.default_provider, model_catalog.default_model_id}

  defp put_new_run_form(socket, params) do
    params = normalize_new_run_model_params(params, socket.assigns.model_catalog)

    socket
    |> assign(:new_run_params, params)
    |> assign(:new_run_form, to_form(params, as: :run))
  end

  defp maybe_put_session_run_form(socket, %{session: %{id: id}} = snapshot, true)
       when is_binary(id) do
    params =
      socket.assigns.new_run_params
      |> Map.merge(session_run_params(snapshot, socket.assigns.model_catalog))
      |> Map.put("objective", "")
      |> Map.put("session_id", id)

    put_new_run_form(socket, params)
  end

  defp maybe_put_session_run_form(socket, _snapshot, _changed?), do: socket

  defp session_run_params(%{session: session} = snapshot, model_catalog) do
    metadata = session.metadata || %{}
    sandbox = field(metadata, :sandbox) || %{}
    runtimes = sandbox |> field(:runtimes) |> List.wrap() |> Enum.map(&to_string/1)
    runtime = sandbox |> field(:runtime) |> sandbox_value(List.first(runtimes) || "bash")
    runtimes = if runtimes == [], do: [runtime], else: runtimes
    {provider, model_id} = model_selection_from_spec(session.model, model_catalog)

    %{
      "agent" => session.agent || "assistant",
      "cwd" => session.workspace_root || File.cwd!(),
      "model_provider" => provider,
      "model_id" => model_id,
      "model" => "#{provider}:#{model_id}",
      "approve" =>
        metadata
        |> field(:runtime_approval)
        |> sandbox_value(selected_approval(snapshot) || "safe"),
      "mode" =>
        metadata |> field(:mode) |> mode_value_string(default_mode_for_agent(session.agent)),
      "write_policy" =>
        metadata
        |> field(:write_policy)
        |> write_policy_value_string(default_mode_for_agent(session.agent)),
      "profile" => metadata |> field(:profile) |> sandbox_value("local-workbench"),
      "sandbox_profile" => sandbox |> field(:sandbox) |> sandbox_value("local_code"),
      "sandbox_backend" => sandbox |> field(:backend) |> sandbox_value("just_bash"),
      "sandbox_runtime" => runtime,
      "sandbox_runtimes" => Enum.join(runtimes, ","),
      "sandbox_network" => sandbox |> field(:network) |> sandbox_value("disabled"),
      "sandbox_stateful" => sandbox |> field(:stateful?) |> sandbox_truthy?() |> to_string(),
      "sandbox_pool_warm" => sandbox |> field(:pool) |> field(:warm) |> integer_string("0"),
      "sandbox_pool_max" => sandbox |> field(:pool) |> field(:max) |> integer_string("1")
    }
  end

  defp default_mode_for_agent("rlm"), do: "patch"
  defp default_mode_for_agent(:rlm), do: "patch"
  defp default_mode_for_agent(_agent), do: "verify"

  defp mode_value_string(nil, fallback), do: fallback
  defp mode_value_string("", fallback), do: fallback
  defp mode_value_string(value, _fallback) when is_atom(value), do: mode_value(value)
  defp mode_value_string(value, _fallback), do: to_string(value)

  defp write_policy_value_string(nil, mode),
    do: mode |> default_write_policy() |> write_policy_value()

  defp write_policy_value_string("", mode), do: write_policy_value_string(nil, mode)
  defp write_policy_value_string(value, _mode), do: write_policy_value(value)

  defp normalize_new_run_model_params(params, model_catalog) do
    provider =
      params
      |> Map.get("model_provider")
      |> valid_provider_or_default(model_catalog)

    models = Map.get(model_catalog.provider_models, provider, [])

    model_id =
      params
      |> Map.get("model_id")
      |> valid_model_or_default(models, provider, model_catalog)

    params
    |> Map.put("model_provider", provider)
    |> Map.put("model_id", model_id)
    |> Map.put("model", "#{provider}:#{model_id}")
  end

  defp valid_provider_or_default(provider, model_catalog) when is_binary(provider) do
    if Map.has_key?(model_catalog.provider_models, provider) do
      provider
    else
      model_catalog.default_provider
    end
  end

  defp valid_provider_or_default(_provider, model_catalog), do: model_catalog.default_provider

  defp valid_model_or_default(model_id, models, provider, model_catalog)
       when is_binary(model_id) do
    if Enum.any?(models, &(&1.id == model_id)) do
      model_id
    else
      default_model_id(models, provider, model_catalog)
    end
  end

  defp valid_model_or_default(_model_id, models, provider, model_catalog),
    do: default_model_id(models, provider, model_catalog)

  defp default_model_id(models, provider, model_catalog) do
    cond do
      provider == model_catalog.default_provider and
          Enum.any?(models, &(&1.id == model_catalog.default_model_id)) ->
        model_catalog.default_model_id

      match?([_ | _], models) ->
        models |> List.first() |> Map.fetch!(:id)

      true ->
        model_catalog.default_model_id
    end
  end

  defp current_model_options(form, model_catalog) do
    provider =
      form
      |> Phoenix.HTML.Form.input_value(:model_provider)
      |> valid_provider_or_default(model_catalog)

    Map.get(model_catalog.provider_models, provider, [])
  end

  defp first_session_id([%{id: id} | _]), do: id
  defp first_session_id(_sessions), do: nil

  defp mode_value(:read_only), do: "read_only"
  defp mode_value(mode), do: Atom.to_string(mode)

  defp write_policy_value(:workspace_review), do: "workspace_review"
  defp write_policy_value(:docs_only), do: "docs_only"
  defp write_policy_value(:none), do: "none"
  defp write_policy_value(policy) when is_binary(policy), do: String.replace(policy, "-", "_")
  defp write_policy_value(policy), do: to_string(policy)

  defp default_write_policy(:patch), do: :workspace_review
  defp default_write_policy("patch"), do: :workspace_review
  defp default_write_policy(_mode), do: :docs_only

  defp landing_agent_modes, do: @landing_agent_modes

  defp sandbox_backend_options do
    [
      {"just_bash", "just bash"},
      {"docker", "docker"},
      {"podman", "podman"},
      {"gvisor", "gvisor"},
      {"vmsan", "vmsan"},
      {"firecracker", "firecracker"},
      {"sprites", "sprites"},
      {"remote", "remote"}
    ]
  end

  defp landing_agent_selected?(form, agent) do
    Phoenix.HTML.Form.input_value(form, :agent) == agent
  end

  defp landing_agent_pressed(form, agent) do
    if landing_agent_selected?(form, agent), do: "true", else: "false"
  end

  defp landing_agent_launch_params("rlm") do
    %{
      "agent" => "rlm",
      "mode" => "patch",
      "write_policy" => "workspace_review"
    }
  end

  defp landing_agent_launch_params(agent) when agent in ["standard", "assistant"] do
    cfg = Workbench.config()
    mode = cfg |> Keyword.get(:default_mode, :verify) |> mode_value()

    write_policy =
      cfg
      |> Keyword.get(:default_write_policy, default_write_policy(mode))
      |> write_policy_value()

    %{
      "agent" => agent,
      "mode" => mode,
      "write_policy" => write_policy
    }
  end

  defp landing_agent_launch_params(_agent), do: %{}

  defp put_default_sandbox_params(params, health) do
    options = landing_sandbox_options(health)

    if Enum.any?(options, &landing_sandbox_selected?(params, &1)) do
      params
    else
      case Enum.find(options, & &1.selectable?) do
        nil -> params
        sandbox -> Map.merge(params, landing_sandbox_launch_params(sandbox))
      end
    end
  end

  defp landing_sandbox_options(health) do
    health
    |> field(:sandbox)
    |> case do
      sandbox when is_map(sandbox) ->
        sandbox
        |> field(:sandboxes)
        |> sandbox_profile_options()

      _sandbox ->
        []
    end
  end

  defp sandbox_profile_options(sandboxes) when is_map(sandboxes) do
    sandboxes
    |> Enum.map(fn {id, profile} -> sandbox_profile_option(id, profile) end)
    |> Enum.sort_by(& &1.sort_key)
  end

  defp sandbox_profile_options(_sandboxes), do: []

  defp sandbox_profile_option(id, profile) do
    backend = profile |> field(:backend) |> sandbox_value("just_bash")
    runtimes = profile |> field(:runtimes) |> List.wrap() |> Enum.map(&to_string/1)
    runtime = List.first(runtimes) || "bash"
    network = profile |> field(:network) |> sandbox_value("disabled")
    stateful? = profile |> field(:stateful?) |> sandbox_truthy?()
    pool = field(profile, :pool) || %{}
    pool_warm = pool |> field(:warm) |> integer_string("0")
    pool_max = pool |> field(:max) |> integer_string("1")
    isolation = profile |> field(:isolation_level) |> sandbox_value("unknown")
    readiness = profile |> field(:readiness) |> sandbox_value("unknown")
    selectable? = profile |> field(:selectable?) |> sandbox_truthy?()

    %{
      id: to_string(id),
      label: sandbox_profile_label(id, backend),
      status_label: profile |> field(:status_label) |> sandbox_text("Unknown"),
      status_detail: profile |> field(:status_detail) |> sandbox_text("Status unavailable"),
      readiness: readiness,
      backend: backend,
      runtime: runtime,
      runtimes: runtimes,
      runtimes_value: Enum.join(runtimes, ","),
      network: network,
      stateful?: stateful?,
      pool_warm: pool_warm,
      pool_max: pool_max,
      isolation: isolation,
      selectable?: selectable? and backend != "",
      active?: profile |> field(:active?) |> sandbox_truthy?(),
      sort_key: sandbox_sort_key(backend, id)
    }
  end

  defp landing_sandbox_option(health, sandbox_id) do
    health
    |> landing_sandbox_options()
    |> Enum.find(&(&1.id == to_string(sandbox_id)))
  end

  defp landing_sandbox_selected?(form_or_params, sandbox) do
    sandbox_form_value(form_or_params, :sandbox_profile) == sandbox.id and
      sandbox_form_value(form_or_params, :sandbox_backend) == sandbox.backend and
      sandbox_form_value(form_or_params, :sandbox_runtime) == sandbox.runtime and
      sandbox_form_value(form_or_params, :sandbox_runtimes) == sandbox.runtimes_value and
      sandbox_form_value(form_or_params, :sandbox_network) == sandbox.network and
      sandbox_form_value(form_or_params, :sandbox_stateful) == to_string(sandbox.stateful?)
  end

  defp landing_sandbox_pressed(form, sandbox) do
    if landing_sandbox_selected?(form, sandbox), do: "true", else: "false"
  end

  defp landing_sandbox_launch_params(sandbox) do
    %{
      "sandbox_profile" => sandbox.id,
      "sandbox_backend" => sandbox.backend,
      "sandbox_runtime" => sandbox.runtime,
      "sandbox_runtimes" => sandbox.runtimes_value,
      "sandbox_network" => sandbox.network,
      "sandbox_stateful" => to_string(sandbox.stateful?),
      "sandbox_pool_warm" => sandbox.pool_warm,
      "sandbox_pool_max" => sandbox.pool_max
    }
  end

  defp selected_landing_sandbox_label(form, health) do
    health
    |> landing_sandbox_options()
    |> Enum.find(&landing_sandbox_selected?(form, &1))
    |> case do
      %{label: label, backend: backend, status_label: status} = sandbox ->
        "#{label} / #{backend}:#{sandbox_runtimes_label(sandbox)} / #{status}"

      _sandbox ->
        selected_landing_sandbox_form_label(form)
    end
  end

  defp selected_landing_sandbox_form_label(form) do
    backend = sandbox_form_value(form, :sandbox_backend)
    runtimes = sandbox_form_value(form, :sandbox_runtimes)

    cond do
      backend != "" and runtimes != "" -> "Selected sandbox / #{backend}:#{runtimes} / Custom"
      backend != "" -> "Selected sandbox / #{backend} / Custom"
      true -> "No available sandbox selected"
    end
  end

  defp sandbox_form_value(%Phoenix.HTML.Form{} = form, field_name) do
    form
    |> Phoenix.HTML.Form.input_value(field_name)
    |> sandbox_value("")
  end

  defp sandbox_form_value(params, field_name) when is_map(params) do
    field = field_name |> Atom.to_string()
    params |> Map.get(field) |> sandbox_value("")
  end

  defp sandbox_value(nil, fallback), do: fallback
  defp sandbox_value("", fallback), do: fallback

  defp sandbox_value(value, _fallback) do
    value
    |> to_string()
    |> String.replace("-", "_")
  end

  defp sandbox_text(nil, fallback), do: fallback
  defp sandbox_text("", fallback), do: fallback
  defp sandbox_text(value, _fallback), do: to_string(value)

  defp integer_string(value, _fallback) when is_integer(value), do: Integer.to_string(value)
  defp integer_string(value, _fallback) when is_binary(value) and value != "", do: value
  defp integer_string(_value, fallback), do: fallback

  defp sandbox_truthy?(value) when value in [true, "true", "1", "yes", "on"], do: true
  defp sandbox_truthy?(_value), do: false

  defp sandbox_sort_key("just_bash", id), do: {0, to_string(id)}
  defp sandbox_sort_key("docker", id), do: {1, to_string(id)}
  defp sandbox_sort_key("gvisor", id), do: {2, to_string(id)}
  defp sandbox_sort_key("vmsan", id), do: {3, to_string(id)}
  defp sandbox_sort_key("firecracker", id), do: {4, to_string(id)}
  defp sandbox_sort_key("sprites", id), do: {5, to_string(id)}
  defp sandbox_sort_key(_backend, id), do: {9, to_string(id)}

  defp sandbox_status_badge_class(%{readiness: "ready"}),
    do: "border-rune-success/30 bg-rune-success/10 text-rune-success"

  defp sandbox_status_badge_class(%{readiness: "busy"}),
    do: "border-rune-warning/30 bg-rune-warning/10 text-rune-warning"

  defp sandbox_status_badge_class(%{readiness: "cold"}),
    do: "border-rune-primary/30 bg-rune-primary/10 text-rune-primary"

  defp sandbox_status_badge_class(_sandbox),
    do: "border-rune-error/30 bg-rune-error/10 text-rune-error"

  defp sandbox_runtimes_label(%{runtimes: runtimes}) when is_list(runtimes) and runtimes != [] do
    runtimes
    |> Enum.join(", ")
  end

  defp sandbox_runtimes_label(_sandbox), do: "none"

  defp sandbox_profile_label(id, "just_bash"), do: "#{titleize_sandbox_id(id)}"
  defp sandbox_profile_label(id, _backend), do: titleize_sandbox_id(id)

  defp titleize_sandbox_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[_-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", fn word -> String.capitalize(word) end)
  end

  defp profile_value(profile) when is_atom(profile),
    do: profile |> Atom.to_string() |> String.replace("_", "-")

  defp profile_value(profile), do: to_string(profile)

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

    <main class="runic-workbench runic-scrollbar h-screen overflow-y-auto px-4 py-6 text-rune-text">
      <section class="mx-auto grid min-h-full w-full max-w-[760px] content-start justify-items-center gap-6">
        <h1 class="sr-only">RunicAI</h1>
        <img
          src={~p"/images/runic-tome-logo.png"}
          alt="RunicAI"
          class="max-h-[220px] w-auto object-contain drop-shadow-[0_28px_70px_rgba(0,0,0,0.46)] max-[700px]:max-h-[160px]"
        />

        <.form
          id="landing-run-form"
          for={@new_run_form}
          phx-change="change_run_form"
          phx-submit="submit_objective"
          class="runic-composer-shell runic-frost grid w-full grid-cols-[1fr_auto] items-end gap-3 rounded-3xl p-3 shadow-[0_22px_70px_rgba(0,0,0,0.34)] max-[700px]:grid-cols-1"
        >
          <div
            role="radiogroup"
            aria-label="Agent mode"
            class="col-span-2 grid grid-cols-3 gap-2 max-[700px]:col-span-1 max-[700px]:grid-cols-1"
          >
            <button
              :for={mode <- landing_agent_modes()}
              type="button"
              phx-click="select_landing_agent"
              phx-value-agent={mode.id}
              aria-pressed={landing_agent_pressed(@new_run_form, mode.id)}
              class={[
                "group grid min-h-[112px] content-between rounded-[22px] border px-4 py-3 text-left transition shadow-[inset_0_1px_0_rgba(255,244,211,0.045)]",
                landing_agent_selected?(@new_run_form, mode.id) &&
                  "border-rune-gold/45 bg-rune-gold/[0.105] text-rune-text shadow-[inset_0_1px_0_rgba(255,244,211,0.08),0_12px_30px_rgba(0,0,0,0.26)]",
                !landing_agent_selected?(@new_run_form, mode.id) &&
                  "border-rune-text/10 bg-black/20 text-rune-text-soft hover:border-rune-gold/30 hover:bg-rune-text/[0.045]"
              ]}
            >
              <span class="flex items-start justify-between gap-3">
                <span class="grid gap-1">
                  <span class="font-display text-[17px] font-semibold leading-tight text-rune-text">
                    {mode.label}
                  </span>
                  <span class="font-mono text-[10px] uppercase text-rune-muted">{mode.meta}</span>
                </span>
                <span class={[
                  "grid size-8 shrink-0 place-items-center rounded-[12px] border",
                  landing_agent_selected?(@new_run_form, mode.id) &&
                    "border-rune-gold/35 bg-rune-gold/15 text-rune-gold",
                  !landing_agent_selected?(@new_run_form, mode.id) &&
                    "border-rune-text/10 bg-black/25 text-rune-primary"
                ]}>
                  <.icon name={mode.icon} class="size-4" />
                </span>
              </span>
              <span class="mt-3 block text-xs leading-5 text-rune-muted group-hover:text-rune-text-soft">
                {mode.detail}
              </span>
            </button>
          </div>

          <details class="col-span-2 overflow-hidden rounded-[22px] border border-rune-text/10 bg-black/15 max-[700px]:col-span-1">
            <summary class="grid cursor-pointer grid-cols-[1fr_auto] items-center gap-3 px-4 py-3 marker:text-rune-gold hover:bg-rune-text/[0.035]">
              <span class="min-w-0">
                <span class="block font-mono text-[10px] uppercase text-rune-muted">
                  Sandbox
                </span>
                <span class="mt-1 block truncate text-sm font-semibold text-rune-text">
                  {selected_landing_sandbox_label(@new_run_form, @health)}
                </span>
              </span>
              <span class="inline-flex items-center gap-2 rounded-full border border-rune-gold/20 bg-rune-gold/10 px-2.5 py-1.5 font-mono text-[10px] uppercase text-rune-gold">
                <.icon name="hero-cube-transparent" class="size-3.5" /> settings
              </span>
            </summary>
            <div class="runic-scrollbar max-h-[34vh] overflow-y-auto border-t border-rune-text/10 p-3">
              <div
                :if={landing_sandbox_options(@health) == []}
                class="rounded-[16px] border border-rune-warning/25 bg-rune-warning/10 px-4 py-3 text-sm leading-6 text-rune-text-soft"
              >
                No sandbox profile is configured for this workbench.
              </div>
              <div
                :if={landing_sandbox_options(@health) != []}
                role="radiogroup"
                aria-label="Sandbox backend"
                class="grid grid-cols-2 gap-2 max-[700px]:grid-cols-1"
              >
                <button
                  :for={sandbox <- landing_sandbox_options(@health)}
                  type="button"
                  phx-click="select_landing_sandbox"
                  phx-value-sandbox={sandbox.id}
                  disabled={!sandbox.selectable?}
                  aria-pressed={landing_sandbox_pressed(@new_run_form, sandbox)}
                  class={[
                    "group grid min-h-[112px] content-between rounded-[18px] border px-4 py-3 text-left transition shadow-[inset_0_1px_0_rgba(255,244,211,0.035)]",
                    landing_sandbox_selected?(@new_run_form, sandbox) &&
                      "border-rune-gold/40 bg-rune-gold/[0.095] text-rune-text shadow-[0_10px_26px_rgba(0,0,0,0.22)]",
                    !landing_sandbox_selected?(@new_run_form, sandbox) &&
                      sandbox.selectable? &&
                      "border-rune-text/10 bg-black/20 text-rune-text-soft hover:border-rune-gold/30 hover:bg-rune-text/[0.045]",
                    !sandbox.selectable? &&
                      "cursor-not-allowed border-rune-text/10 bg-black/10 text-rune-muted opacity-70"
                  ]}
                >
                  <span class="flex items-start justify-between gap-3">
                    <span class="min-w-0">
                      <span class="block truncate font-display text-[16px] font-semibold leading-tight text-rune-text">
                        {sandbox.label}
                      </span>
                      <span class="mt-1 block truncate font-mono text-[10px] uppercase text-rune-muted">
                        {sandbox.backend} / {sandbox.isolation}
                      </span>
                      <span class={[
                        "mt-2 inline-flex max-w-full items-center rounded-full border px-2 py-1 font-mono text-[10px] uppercase",
                        sandbox_status_badge_class(sandbox)
                      ]}>
                        <span class="truncate">{sandbox.status_label}</span>
                      </span>
                    </span>
                    <span class={[
                      "grid size-8 shrink-0 place-items-center rounded-[12px] border",
                      landing_sandbox_selected?(@new_run_form, sandbox) &&
                        "border-rune-gold/35 bg-rune-gold/15 text-rune-gold",
                      !landing_sandbox_selected?(@new_run_form, sandbox) &&
                        "border-rune-text/10 bg-black/25 text-rune-primary"
                    ]}>
                      <.icon name="hero-cpu-chip" class="size-4" />
                    </span>
                  </span>
                  <span class="mt-3 grid grid-cols-2 gap-x-3 gap-y-1 font-mono text-[10.5px] text-rune-muted">
                    <span class="truncate">runtimes {sandbox_runtimes_label(sandbox)}</span>
                    <span class="truncate">network {sandbox.network}</span>
                    <span class="truncate">
                      {if sandbox.stateful?, do: "stateful", else: "stateless"}
                    </span>
                    <span class="truncate">pool {sandbox.pool_warm}/{sandbox.pool_max}</span>
                  </span>
                  <span class="mt-2 block truncate text-xs leading-5 text-rune-muted">
                    {sandbox.status_detail}
                  </span>
                </button>
              </div>
            </div>
          </details>

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
            name={@new_run_form[:write_policy].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :write_policy)}
          />
          <input
            type="hidden"
            name={@new_run_form[:cwd].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :cwd)}
          />
          <input
            type="hidden"
            name={@new_run_form[:model_provider].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :model_provider)}
          />
          <input
            type="hidden"
            name={@new_run_form[:model_id].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :model_id)}
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
          <input
            type="hidden"
            name={@new_run_form[:profile].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :profile)}
          />
          <input
            type="hidden"
            name={@new_run_form[:toolsets].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :toolsets)}
          />
          <input
            type="hidden"
            name={@new_run_form[:disabled_tools].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :disabled_tools)}
          />
          <input
            type="hidden"
            name={@new_run_form[:tool_config].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :tool_config)}
          />
          <input
            type="hidden"
            name={@new_run_form[:sandbox_profile].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_profile)}
          />
          <input
            type="hidden"
            name={@new_run_form[:sandbox_backend].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_backend)}
          />
          <input
            type="hidden"
            name={@new_run_form[:sandbox_runtime].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_runtime)}
          />
          <input
            type="hidden"
            name={@new_run_form[:sandbox_runtimes].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_runtimes)}
          />
          <input
            type="hidden"
            name={@new_run_form[:sandbox_network].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_network)}
          />
          <input
            type="hidden"
            name={@new_run_form[:sandbox_stateful].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_stateful)}
          />
          <input
            type="hidden"
            name={@new_run_form[:sandbox_pool_warm].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_pool_warm)}
          />
          <input
            type="hidden"
            name={@new_run_form[:sandbox_pool_max].name}
            value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_pool_max)}
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
            <.health_row label="sandbox" value={sandbox_health(@health)} />
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
                        <div
                          :if={message_blocked_next_actions(message) != []}
                          class="mt-3 grid gap-1.5 border-t border-rune-gold/20 pt-3"
                        >
                          <div
                            :for={action <- message_blocked_next_actions(message)}
                            class="flex items-start gap-2"
                          >
                            <.icon
                              name="hero-arrow-right"
                              class="mt-0.5 size-3.5 shrink-0 text-rune-gold"
                            />
                            <span>{action}</span>
                          </div>
                        </div>
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
                <div class="grid gap-3.5">
                  <div class="grid grid-cols-4 gap-3.5 max-[1240px]:grid-cols-2 max-[880px]:grid-cols-1">
                    <.plan_step :for={step <- plan_steps(@snapshot)} step={step} />
                  </div>
                  <div :if={@snapshot.plan_workflow_graph}>
                    <.graph_canvas
                      graph={@snapshot.plan_workflow_graph}
                      id={"plan-workflow-graph-#{dom_id(selected_session_id(@snapshot))}"}
                    />
                  </div>
                  <div class="grid grid-cols-3 gap-3.5 max-[1240px]:grid-cols-2 max-[880px]:grid-cols-1">
                    <.progress_summary_panel summary={@snapshot.progress_summary} />
                    <.objective_loop_panel loop={@snapshot.objective_loop} />
                    <.objective_contract_panel contract={@snapshot.objective_contract} />
                    <.blocked_evidence_panel evidence={@snapshot.blocked_evidence} />
                  </div>
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
              id={"session-run-form-#{dom_id(selected_session_id(@snapshot))}"}
              for={@new_run_form}
              phx-change="change_run_form"
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
                      workflow rlm
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
                      verify / inspect
                    </option>
                    <option
                      value="patch"
                      selected={Phoenix.HTML.Form.input_value(@new_run_form, :mode) == "patch"}
                    >
                      patch / write
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
                    value="always"
                    selected={Phoenix.HTML.Form.input_value(@new_run_form, :approve) == "always"}
                  >
                    approve all
                  </option>
                  <option
                    value="safe"
                    selected={Phoenix.HTML.Form.input_value(@new_run_form, :approve) == "safe"}
                  >
                    safe auto-approve
                  </option>
                  <option
                    value="ask"
                    selected={Phoenix.HTML.Form.input_value(@new_run_form, :approve) == "ask"}
                  >
                    ask each time
                  </option>
                  <option
                    value="never"
                    selected={Phoenix.HTML.Form.input_value(@new_run_form, :approve) == "never"}
                  >
                    never approve
                  </option>
                </select>
                <details class="rounded-[11px] border border-rune-text/5 bg-black/20 px-3 py-2 text-[11px] leading-5 text-rune-text-soft">
                  <summary class="cursor-pointer font-mono text-[10px] uppercase tracking-[0.08em] text-rune-muted">
                    Run setup
                  </summary>
                  <div class="mt-2 grid gap-2">
                    <label class="grid gap-1">
                      <span class="font-mono text-[10px] uppercase text-rune-muted">Profile</span>
                      <select
                        name={@new_run_form[:profile].name}
                        class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft"
                      >
                        <option
                          value="local-workbench"
                          selected={
                            Phoenix.HTML.Form.input_value(@new_run_form, :profile) ==
                              "local-workbench"
                          }
                        >
                          local workbench
                        </option>
                        <option
                          value="coding-verify"
                          selected={
                            Phoenix.HTML.Form.input_value(@new_run_form, :profile) == "coding-verify"
                          }
                        >
                          coding verify
                        </option>
                        <option
                          value="coding-patch"
                          selected={
                            Phoenix.HTML.Form.input_value(@new_run_form, :profile) == "coding-patch"
                          }
                        >
                          coding patch
                        </option>
                        <option
                          value="coding-read"
                          selected={
                            Phoenix.HTML.Form.input_value(@new_run_form, :profile) == "coding-read"
                          }
                        >
                          coding read
                        </option>
                        <option
                          value="safe"
                          selected={Phoenix.HTML.Form.input_value(@new_run_form, :profile) == "safe"}
                        >
                          safe
                        </option>
                        <option
                          value="full-local"
                          selected={
                            Phoenix.HTML.Form.input_value(@new_run_form, :profile) == "full-local"
                          }
                        >
                          full local
                        </option>
                      </select>
                    </label>
                    <div class="grid grid-cols-2 gap-2 max-[700px]:grid-cols-1">
                      <label class="grid gap-1">
                        <span class="font-mono text-[10px] uppercase text-rune-muted">
                          Provider
                        </span>
                        <select
                          name={@new_run_form[:model_provider].name}
                          class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft"
                        >
                          <option
                            :for={provider <- @model_catalog.providers}
                            value={provider.id}
                            selected={
                              Phoenix.HTML.Form.input_value(@new_run_form, :model_provider) ==
                                provider.id
                            }
                          >
                            {provider.label}
                          </option>
                        </select>
                      </label>
                      <label class="grid gap-1">
                        <span class="font-mono text-[10px] uppercase text-rune-muted">Model</span>
                        <select
                          name={@new_run_form[:model_id].name}
                          class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft"
                        >
                          <option
                            :for={model <- current_model_options(@new_run_form, @model_catalog)}
                            value={model.id}
                            selected={
                              Phoenix.HTML.Form.input_value(@new_run_form, :model_id) == model.id
                            }
                          >
                            {model.label}
                          </option>
                        </select>
                        <input
                          type="hidden"
                          name={@new_run_form[:model].name}
                          value={Phoenix.HTML.Form.input_value(@new_run_form, :model)}
                        />
                      </label>
                    </div>
                    <label class="grid gap-1">
                      <span class="font-mono text-[10px] uppercase text-rune-muted">
                        Write policy
                      </span>
                      <select
                        name={@new_run_form[:write_policy].name}
                        class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft"
                      >
                        <option
                          value="workspace_review"
                          selected={
                            Phoenix.HTML.Form.input_value(@new_run_form, :write_policy) ==
                              "workspace_review"
                          }
                        >
                          workspace writes gated
                        </option>
                        <option
                          value="docs_only"
                          selected={
                            Phoenix.HTML.Form.input_value(@new_run_form, :write_policy) ==
                              "docs_only"
                          }
                        >
                          docs only
                        </option>
                        <option
                          value="none"
                          selected={
                            Phoenix.HTML.Form.input_value(@new_run_form, :write_policy) == "none"
                          }
                        >
                          no artifact writes
                        </option>
                      </select>
                    </label>
                    <div class="grid grid-cols-2 gap-2 max-[700px]:grid-cols-1">
                      <label class="grid gap-1">
                        <span class="font-mono text-[10px] uppercase text-rune-muted">
                          Sandbox backend
                        </span>
                        <select
                          name={@new_run_form[:sandbox_backend].name}
                          class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft"
                        >
                          <option
                            :for={{backend, label} <- sandbox_backend_options()}
                            value={backend}
                            selected={
                              Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_backend) ==
                                backend
                            }
                          >
                            {label}
                          </option>
                        </select>
                      </label>
                      <label class="grid gap-1">
                        <span class="font-mono text-[10px] uppercase text-rune-muted">
                          Sandbox runtime
                        </span>
                        <select
                          name={@new_run_form[:sandbox_runtime].name}
                          class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft"
                        >
                          <option
                            :for={runtime <- ~w(bash python node elixir lua)}
                            value={runtime}
                            selected={
                              Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_runtime) ==
                                runtime
                            }
                          >
                            {runtime}
                          </option>
                        </select>
                      </label>
                    </div>
                    <div class="grid grid-cols-2 gap-2 max-[700px]:grid-cols-1">
                      <label class="grid gap-1">
                        <span class="font-mono text-[10px] uppercase text-rune-muted">
                          Sandbox network
                        </span>
                        <select
                          name={@new_run_form[:sandbox_network].name}
                          class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft"
                        >
                          <option
                            value="disabled"
                            selected={
                              Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_network) ==
                                "disabled"
                            }
                          >
                            disabled
                          </option>
                          <option
                            value="restricted"
                            selected={
                              Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_network) ==
                                "restricted"
                            }
                          >
                            restricted
                          </option>
                          <option
                            value="host"
                            selected={
                              Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_network) ==
                                "host"
                            }
                          >
                            host
                          </option>
                        </select>
                      </label>
                      <label class="grid gap-1">
                        <span class="font-mono text-[10px] uppercase text-rune-muted">
                          Sandbox state
                        </span>
                        <select
                          name={@new_run_form[:sandbox_stateful].name}
                          class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft"
                        >
                          <option
                            value="false"
                            selected={
                              Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_stateful) ==
                                "false"
                            }
                          >
                            stateless
                          </option>
                          <option
                            value="true"
                            selected={
                              Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_stateful) ==
                                "true"
                            }
                          >
                            stateful
                          </option>
                        </select>
                      </label>
                    </div>
                    <div class="grid grid-cols-2 gap-2 max-[700px]:grid-cols-1">
                      <label class="grid gap-1">
                        <span class="font-mono text-[10px] uppercase text-rune-muted">
                          Pool warm
                        </span>
                        <input
                          type="number"
                          min="0"
                          name={@new_run_form[:sandbox_pool_warm].name}
                          value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_pool_warm)}
                          class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft outline-none"
                        />
                      </label>
                      <label class="grid gap-1">
                        <span class="font-mono text-[10px] uppercase text-rune-muted">
                          Pool max
                        </span>
                        <input
                          type="number"
                          min="1"
                          name={@new_run_form[:sandbox_pool_max].name}
                          value={Phoenix.HTML.Form.input_value(@new_run_form, :sandbox_pool_max)}
                          class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft outline-none"
                        />
                      </label>
                    </div>
                    <label class="grid gap-1">
                      <span class="font-mono text-[10px] uppercase text-rune-muted">Toolsets</span>
                      <input
                        type="text"
                        name={@new_run_form[:toolsets].name}
                        value={Phoenix.HTML.Form.input_value(@new_run_form, :toolsets)}
                        placeholder="file,git,patch,terminal,code_execution"
                        class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft outline-none placeholder:text-rune-muted"
                      />
                    </label>
                    <label class="grid gap-1">
                      <span class="font-mono text-[10px] uppercase text-rune-muted">
                        Disabled tools
                      </span>
                      <input
                        type="text"
                        name={@new_run_form[:disabled_tools].name}
                        value={Phoenix.HTML.Form.input_value(@new_run_form, :disabled_tools)}
                        placeholder="run_formatter,process_kill"
                        class="min-h-[31px] rounded-[11px] border border-rune-text/5 bg-black/25 px-2 py-1.5 font-mono text-[11px] text-rune-text-soft outline-none placeholder:text-rune-muted"
                      />
                    </label>
                    <input
                      type="hidden"
                      name={@new_run_form[:tool_config].name}
                      value={Phoenix.HTML.Form.input_value(@new_run_form, :tool_config)}
                    />
                    <p>
                      <strong class="text-rune-text">assistant</strong>: structured/source-grounded workflows
                    </p>
                    <p>
                      <strong class="text-rune-text">standard</strong>: direct conversational/local runs
                    </p>
                    <p>
                      <strong class="text-rune-text">workflow rlm</strong>: objective-gated coding/workflow coordination; patch mode keeps it on the RLM runner
                    </p>
                    <p>
                      <strong class="text-rune-text">verify</strong>: inspect/analyze, <strong class="text-rune-text">patch</strong>: may write workspace files, <strong class="text-rune-text">read only</strong>: no writes expected
                    </p>
                    <p>
                      <strong class="text-rune-text">approve all</strong>: approve non-budget review gates, <strong class="text-rune-text">safe</strong>: auto-approve low-risk gated actions only, <strong class="text-rune-text">ask</strong>: pause in browser, <strong class="text-rune-text">never</strong>: deny gated actions
                    </p>
                    <p>
                      <strong class="text-rune-text">workspace writes gated</strong>: allow non-doc artifacts inside the selected cwd after policy review
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
              <div class="px-[18px] pb-3 pt-1">
                <.progress_summary_panel summary={@snapshot.progress_summary} compact />
              </div>
              <div
                :if={snapshot_sandbox_executions(@snapshot) != []}
                class="px-[18px] pb-3 pt-1"
              >
                <div class="mb-2 font-mono text-[10.5px] font-bold uppercase text-rune-muted">
                  Sandbox executions
                </div>
                <.artifact_record
                  :for={execution <- Enum.take(snapshot_sandbox_executions(@snapshot), 4)}
                  title={sandbox_execution_title(execution)}
                  meta={execution.status}
                  tone={execution.status}
                  detail={sandbox_execution_detail(execution)}
                />
              </div>
              <div
                :if={snapshot_child_repairs(@snapshot) != []}
                class="px-[18px] pb-3 pt-1"
              >
                <div class="mb-2 font-mono text-[10.5px] font-bold uppercase text-rune-muted">
                  Child repairs
                </div>
                <.child_repair_record
                  :for={repair <- Enum.take(snapshot_child_repairs(@snapshot), 4)}
                  repair={repair}
                />
              </div>
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
                  <dt class="text-rune-muted">profile</dt>
                  <dd>{capability_name(@snapshot) || "-"}</dd>
                  <dt class="text-rune-muted">toolsets</dt>
                  <dd class="truncate">{capability_toolsets(@snapshot)}</dd>
                  <dt class="text-rune-muted">browser</dt>
                  <dd class="truncate">{agent_browser_status(@snapshot)}</dd>
                  <dt class="text-rune-muted">sandbox</dt>
                  <dd class="truncate">{sandbox_profile_label(@snapshot)}</dd>
                  <dt class="text-rune-muted">gated</dt>
                  <dd class="truncate">{capability_gated_tools(@snapshot)}</dd>
                  <dt class="text-rune-muted">database</dt>
                  <dd class="truncate">{Path.basename(to_string(@health.database || "memory"))}</dd>
                  <dt class="text-rune-muted">messages</dt>
                  <dd>{@snapshot.metrics.messages}</dd>
                  <dt class="text-rune-muted">events</dt>
                  <dd>{@snapshot.metrics.events}</dd>
                  <dt class="text-rune-muted">sandbox execs</dt>
                  <dd>{@snapshot.metrics.sandbox_executions}</dd>
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
      ></button>
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
        <div class="grid grid-cols-2 gap-2">
          <label class="grid gap-1 font-mono text-[10px] uppercase text-rune-muted">
            Extra loops
            <input
              type="number"
              min="1"
              name="review[additional_iterations]"
              class="min-h-[34px] rounded-[11px] border border-rune-text/5 bg-black/20 px-3 py-2 text-xs text-rune-text outline-none"
              placeholder="1"
            />
          </label>
          <label class="grid gap-1 font-mono text-[10px] uppercase text-rune-muted">
            Extra runtime ms
            <input
              type="number"
              min="1000"
              step="1000"
              name="review[additional_runtime_ms]"
              class="min-h-[34px] rounded-[11px] border border-rune-text/5 bg-black/20 px-3 py-2 text-xs text-rune-text outline-none"
              placeholder="300000"
            />
          </label>
        </div>
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
      <.form
        :if={review_open?(@review)}
        id={"approval-policy-form-#{dom_id(@review.id)}"}
        for={%{}}
        as={:approval}
        phx-submit="approval_policy"
        class="px-[18px] pb-[18px]"
      >
        <input type="hidden" name="approval[policy]" value="always" />
        <button
          type="submit"
          class="min-h-[34px] rounded-[11px] border border-rune-primary/25 bg-rune-primary/10 px-3 py-2 text-xs font-semibold text-rune-primary-soft hover:border-rune-primary/45"
        >
          Approve tool reviews for session
        </button>
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

  attr :summary, :any, default: %{}
  attr :compact, :boolean, default: false

  defp progress_summary_panel(assigns) do
    ~H"""
    <section class={[
      "rounded-2xl border border-rune-text/10 bg-black/25 px-4 py-4 shadow-[inset_0_1px_0_rgba(255,244,211,0.035),0_12px_34px_rgba(0,0,0,0.18)]",
      !@compact && "min-h-[188px]"
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <span class="font-mono text-[10.5px] font-semibold uppercase text-rune-muted">
            Live progress
          </span>
          <strong class="mt-1 block truncate text-sm leading-snug text-rune-text">
            {progress_latest_title(@summary)}
          </strong>
        </div>
        <span class="shrink-0 rounded-full border border-rune-text/5 bg-black/25 px-2 py-1 font-mono text-[10px] text-rune-primary">
          {progress_event_trail(@summary)}
        </span>
      </div>

      <p
        :if={progress_latest_detail(@summary)}
        class="mt-2 line-clamp-2 text-xs leading-5 text-rune-text-soft"
      >
        {progress_latest_detail(@summary)}
      </p>

      <div :if={progress_facts(@summary) != []} class="mt-3 grid grid-cols-2 gap-2">
        <div
          :for={fact <- progress_facts(@summary)}
          class="rounded-xl border border-rune-text/5 bg-black/20 px-3 py-2"
        >
          <span class="block font-mono text-[10px] uppercase text-rune-muted">{fact.label}</span>
          <span class="mt-1 block truncate text-xs text-rune-text-soft">{fact.value}</span>
        </div>
      </div>
    </section>
    """
  end

  attr :contract, :any, default: nil

  attr :loop, :any, default: nil

  defp objective_loop_panel(assigns) do
    ~H"""
    <section class="min-h-[188px] rounded-2xl border border-rune-text/10 bg-black/25 px-4 py-4 shadow-[inset_0_1px_0_rgba(255,244,211,0.035),0_12px_34px_rgba(0,0,0,0.18)]">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <span class="font-mono text-[10.5px] font-semibold uppercase text-rune-muted">
            Objective loop
          </span>
          <strong class="mt-1 block truncate text-sm leading-snug text-rune-text">
            {objective_loop_status(@loop)}
          </strong>
        </div>
        <span
          :if={objective_loop_action(@loop)}
          class="shrink-0 rounded-full border border-rune-primary/20 bg-rune-primary/10 px-2 py-1 font-mono text-[10px] text-rune-primary"
        >
          {objective_loop_action(@loop)}
        </span>
      </div>

      <div :if={objective_loop_facts(@loop) != []} class="mt-3 grid grid-cols-2 gap-2">
        <div
          :for={fact <- objective_loop_facts(@loop)}
          class="rounded-xl border border-rune-text/5 bg-black/20 px-3 py-2"
        >
          <span class="block font-mono text-[10px] uppercase text-rune-muted">{fact.label}</span>
          <span class="mt-1 block truncate text-xs text-rune-text-soft">{fact.value}</span>
        </div>
      </div>

      <div :if={objective_loop_tasks(@loop) != []} class="mt-3 grid gap-1.5">
        <div
          :for={task <- objective_loop_tasks(@loop)}
          class="flex items-start gap-2 text-xs leading-5 text-rune-text-soft"
        >
          <.icon name="hero-arrow-path" class="mt-0.5 size-3.5 shrink-0 text-rune-gold" />
          <span>{objective_loop_task_text(task)}</span>
        </div>
      </div>

      <div
        :if={objective_loop_budget_requests(@loop) != []}
        class="mt-3 rounded-xl border border-rune-warning/20 bg-rune-warning/10 px-3 py-2"
      >
        <span class="font-mono text-[10px] uppercase text-rune-warning">Budget request</span>
        <p class="mt-1 line-clamp-2 text-xs leading-5 text-rune-text-soft">
          {objective_loop_budget_reason(@loop)}
        </p>
      </div>

      <div
        :if={objective_loop_review_requests(@loop) != []}
        class="mt-3 rounded-xl border border-rune-primary/20 bg-rune-primary/10 px-3 py-2"
      >
        <span class="font-mono text-[10px] uppercase text-rune-primary">Review request</span>
        <p class="mt-1 line-clamp-2 text-xs leading-5 text-rune-text-soft">
          {objective_loop_review_reason(@loop)}
        </p>
      </div>

      <p
        :if={
          objective_loop_facts(@loop) == [] and objective_loop_tasks(@loop) == [] and
            objective_loop_budget_requests(@loop) == [] and
            objective_loop_review_requests(@loop) == []
        }
        class="mt-6 text-sm leading-6 text-rune-muted"
      >
        No objective loop captured for this session.
      </p>
    </section>
    """
  end

  attr :contract, :any, default: nil

  defp objective_contract_panel(assigns) do
    ~H"""
    <section class="min-h-[188px] rounded-2xl border border-rune-text/10 bg-black/25 px-4 py-4 shadow-[inset_0_1px_0_rgba(255,244,211,0.035),0_12px_34px_rgba(0,0,0,0.18)]">
      <div class="flex items-start justify-between gap-3">
        <div>
          <span class="font-mono text-[10.5px] font-semibold uppercase text-rune-muted">
            Objective contract
          </span>
          <strong class="mt-1 block text-sm leading-snug text-rune-text">
            {contract_domain(@contract)}
          </strong>
        </div>
        <span
          :if={contract_profile(@contract)}
          class="shrink-0 rounded-full border border-rune-text/5 bg-black/25 px-2 py-1 font-mono text-[10px] text-rune-gold"
        >
          {contract_profile(@contract)}
        </span>
      </div>

      <div
        :if={contract_evidence_required(@contract) != []}
        class="mt-3 flex flex-wrap gap-1.5"
      >
        <span
          :for={evidence <- contract_evidence_required(@contract)}
          class="rounded-full border border-rune-primary/20 bg-rune-primary/10 px-2 py-1 font-mono text-[10px] text-rune-primary"
        >
          {evidence}
        </span>
      </div>

      <div :if={contract_requirements(@contract) != []} class="mt-3 grid gap-2">
        <div
          :for={requirement <- contract_requirements(@contract)}
          class="rounded-xl border border-rune-text/5 bg-black/20 px-3 py-2"
        >
          <span class="block font-mono text-[10px] text-rune-gold">
            {contract_requirement_id(requirement)}
          </span>
          <span class="mt-1 block text-xs leading-5 text-rune-text-soft">
            {contract_requirement_text(requirement)}
          </span>
        </div>
      </div>

      <p :if={contract_requirements(@contract) == []} class="mt-6 text-sm leading-6 text-rune-muted">
        No objective contract captured for this session.
      </p>
    </section>
    """
  end

  attr :evidence, :any, default: nil

  defp blocked_evidence_panel(assigns) do
    ~H"""
    <section class="min-h-[188px] rounded-2xl border border-rune-text/10 bg-black/25 px-4 py-4 shadow-[inset_0_1px_0_rgba(255,244,211,0.035),0_12px_34px_rgba(0,0,0,0.18)]">
      <div class="flex items-start justify-between gap-3">
        <div>
          <span class="font-mono text-[10.5px] font-semibold uppercase text-rune-muted">
            Blocked evidence
          </span>
          <strong class="mt-1 block text-sm leading-snug text-rune-text">
            {blocked_status(@evidence)}
          </strong>
        </div>
        <span
          :if={blocked_current_node(@evidence)}
          class="shrink-0 rounded-full border border-rune-warning/25 bg-rune-warning/10 px-2 py-1 font-mono text-[10px] text-rune-warning"
        >
          {blocked_current_node(@evidence)}
        </span>
      </div>

      <div :if={blocked_facts(@evidence) != []} class="mt-3 grid grid-cols-2 gap-2">
        <div
          :for={fact <- blocked_facts(@evidence)}
          class="rounded-xl border border-rune-text/5 bg-black/20 px-3 py-2"
        >
          <span class="block font-mono text-[10px] uppercase text-rune-muted">{fact.label}</span>
          <span class="mt-1 block truncate text-xs text-rune-text-soft">{fact.value}</span>
        </div>
      </div>

      <div :if={blocked_next_actions(@evidence) != []} class="mt-3 grid gap-1.5">
        <div
          :for={action <- blocked_next_actions(@evidence)}
          class="flex items-start gap-2 text-xs leading-5 text-rune-text-soft"
        >
          <.icon name="hero-arrow-right" class="mt-0.5 size-3.5 shrink-0 text-rune-gold" />
          <span>{action}</span>
        </div>
      </div>

      <p :if={blocked_next_actions(@evidence) == []} class="mt-6 text-sm leading-6 text-rune-muted">
        No blocked evidence for this session.
      </p>
    </section>
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

  attr :repair, :map, required: true

  defp child_repair_record(assigns) do
    ~H"""
    <div class="mb-3 rounded-[17px] border border-rune-gold/15 bg-rune-gold/[0.055] p-[15px] shadow-[inset_0_1px_0_rgba(255,215,128,0.07)]">
      <div class="mb-2 flex items-center justify-between gap-2 font-mono text-[10.5px] text-rune-muted">
        <span class="truncate">{child_repair_meta(@repair)}</span>
        <span class={["rounded-full px-2 py-1 uppercase", child_repair_status_class(@repair)]}>
          {field(@repair, :status)}
        </span>
      </div>
      <h3 class="text-[13px] font-semibold leading-snug text-rune-text">
        {field(@repair, :title)}
      </h3>
      <p class="mt-2 line-clamp-3 text-xs leading-5 text-rune-text-soft">
        {field(@repair, :detail)}
      </p>
      <div class="mt-3 grid grid-cols-2 gap-2">
        <div
          :for={fact <- child_repair_facts(@repair)}
          class="rounded-xl border border-rune-text/5 bg-black/20 px-3 py-2"
        >
          <span class="block font-mono text-[10px] uppercase text-rune-muted">{fact.label}</span>
          <span class="mt-1 block truncate text-xs text-rune-text-soft">{fact.value}</span>
        </div>
      </div>
      <div
        :if={child_repair_next_action(@repair)}
        class="mt-3 flex items-start gap-2 rounded-xl border border-rune-primary/15 bg-rune-primary/[0.075] px-3 py-2 text-xs leading-5 text-rune-text-soft"
      >
        <.icon name="hero-arrow-right" class="mt-0.5 size-3.5 shrink-0 text-rune-primary" />
        <span>{child_repair_next_action(@repair)}</span>
      </div>
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

  defp child_repair_meta(repair) do
    [
      field(repair, :type),
      field(repair, :node_id),
      child_repair_attempt_label(repair)
    ]
    |> Enum.map(&present_string/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" - ")
  end

  defp child_repair_attempt_label(repair) do
    case field(repair, :attempt) do
      nil -> nil
      attempt -> "attempt #{attempt}"
    end
  end

  defp child_repair_status_class(repair) do
    case field(repair, :status) do
      "repaired" -> "bg-rune-primary/15 text-rune-primary"
      "running" -> "bg-rune-gold/15 text-rune-gold"
      "unresolved" -> "bg-rune-warning/15 text-rune-warning"
      _other -> event_status_class(field(repair, :status))
    end
  end

  defp child_repair_facts(repair) do
    [
      %{label: "reason", value: present_string(field(repair, :reason))},
      %{label: "changed", value: child_repair_changed_label(repair)},
      %{label: "diagnostic", value: child_repair_diagnostic_label(repair)},
      %{label: "mode", value: present_string(field(repair, :mode))}
    ]
    |> Enum.reject(fn fact -> fact.value in [nil, ""] end)
  end

  defp child_repair_changed_label(repair) do
    files = field(repair, :changed_files) |> List.wrap() |> Enum.reject(&is_nil/1)

    case files do
      [] -> nil
      [file] -> file
      files -> "#{length(files)} files"
    end
  end

  defp child_repair_diagnostic_label(repair) do
    repair
    |> field(:diagnostics)
    |> List.wrap()
    |> case do
      [] -> nil
      [diagnostic | _rest] -> child_repair_diagnostic_text(diagnostic)
    end
  end

  defp child_repair_diagnostic_text(diagnostic) when is_map(diagnostic) do
    message = field(diagnostic, :message)
    code = field(diagnostic, :code)
    details = field(diagnostic, :details)
    op = field(details, :op)

    [message, code, op && "op=#{op}"]
    |> Enum.map(&present_string/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" - ")
  end

  defp child_repair_diagnostic_text(diagnostic), do: present_string(diagnostic)

  defp child_repair_next_action(repair), do: field(repair, :next_action)

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

  defp selected_session_id(%{session: %{id: id}}) when is_binary(id), do: id
  defp selected_session_id(_snapshot), do: "none"

  defp snapshot_sandbox_executions(%{sandbox_executions: executions}) when is_list(executions),
    do: executions

  defp snapshot_sandbox_executions(_snapshot), do: []

  defp snapshot_child_repairs(%{child_repairs: repairs}) when is_list(repairs), do: repairs
  defp snapshot_child_repairs(_snapshot), do: []

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

  defp capability_name(snapshot) do
    snapshot
    |> capability_profile()
    |> field(:name)
  end

  defp capability_toolsets(snapshot) do
    snapshot
    |> capability_profile()
    |> field(:toolsets)
    |> list_label()
  end

  defp capability_gated_tools(snapshot) do
    snapshot
    |> capability_profile()
    |> field(:gated_tools)
    |> list_label()
  end

  defp agent_browser_status(snapshot) do
    profile = capability_profile(snapshot)
    toolsets = field(profile, :toolsets) || []

    if "browser" in Enum.map(List.wrap(toolsets), &to_string/1) do
      "agent browser enabled"
    else
      "-"
    end
  end

  defp sandbox_profile_label(snapshot) do
    code_execution =
      snapshot
      |> capability_profile()
      |> field(:config)
      |> field(:code_execution)

    backend = field(code_execution, :default_backend) || field(code_execution, :backend)
    network = field(code_execution, :network)
    runtimes = field(code_execution, :allowed_runtimes) || field(code_execution, :runtimes)

    case {backend, runtimes, network} do
      {nil, nil, nil} ->
        "-"

      _other ->
        [
          backend || "sandbox",
          runtimes |> List.wrap() |> Enum.map(&to_string/1) |> Enum.join("/"),
          network || :disabled
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.map(&to_string/1)
        |> Enum.join(" - ")
    end
  end

  defp sandbox_execution_title(execution) do
    backend = field(execution, :backend) || field(execution, :sandbox) || "sandbox"
    runtime = field(execution, :runtime) || "runtime"
    proof = sandbox_execution_proof_label(execution)

    [backend, runtime, proof]
    |> Enum.reject(&(&1 in [nil, "", "-"]))
    |> Enum.map(&to_string/1)
    |> Enum.join(" / ")
  end

  defp sandbox_execution_detail(execution) do
    [
      field(execution, :isolation_level),
      field(execution, :network),
      sandbox_security_boundary_label(field(execution, :security_boundary?)),
      sandbox_copy_label("copy-in", field(execution, :copy_in_status)),
      sandbox_copy_label("copy-back", field(execution, :copy_back_status)),
      sandbox_duration_label(field(execution, :duration_ms)),
      changed_files_label(field(execution, :files_changed))
    ]
    |> Enum.reject(&(&1 in [nil, "", "-"]))
    |> Enum.map(&to_string/1)
    |> Enum.join(" - ")
  end

  defp sandbox_execution_proof_label(execution) do
    proof = field(execution, :proof) || %{}

    cond do
      field(proof, :session_id) not in [nil, ""] ->
        "session #{short_id(field(proof, :session_id))}"

      field(proof, :vm_id) not in [nil, ""] ->
        "vm #{short_id(field(proof, :vm_id))}"

      field(proof, :container_name) not in [nil, ""] ->
        "container #{short_id(field(proof, :container_name))}"

      field(proof, :execution_event_id) not in [nil, ""] ->
        "event #{short_id(field(proof, :execution_event_id))}"

      true ->
        nil
    end
  end

  defp sandbox_security_boundary_label(true), do: "security boundary"
  defp sandbox_security_boundary_label("true"), do: "security boundary"
  defp sandbox_security_boundary_label(_value), do: nil

  defp sandbox_copy_label(_label, value) when value in [nil, ""], do: nil
  defp sandbox_copy_label(label, value), do: "#{label} #{value}"

  defp sandbox_duration_label(duration_ms) when is_integer(duration_ms), do: "#{duration_ms}ms"
  defp sandbox_duration_label(_duration_ms), do: nil

  defp changed_files_label(files) when is_list(files) and files != [],
    do: "#{length(files)} changed"

  defp changed_files_label(_files), do: nil

  defp short_id(value) do
    value
    |> to_string()
    |> String.slice(0, 18)
  end

  defp capability_profile(%{capability_profile: profile}) when is_map(profile), do: profile

  defp capability_profile(%{session: %{capability_profile: profile}}) when is_map(profile),
    do: profile

  defp capability_profile(%{session: %{metadata: metadata}}) when is_map(metadata),
    do: field(metadata, :capability_profile) || %{}

  defp capability_profile(_snapshot), do: %{}

  defp list_label(values) when is_list(values) and values != [] do
    values
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end

  defp list_label(_values), do: "-"

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  defp first_present(nil, fallback), do: fallback
  defp first_present("", fallback), do: fallback
  defp first_present(value, _fallback), do: value

  defp selected_short_id(%{session: %{short_id: short_id}}) when is_binary(short_id), do: short_id
  defp selected_short_id(%{session: %{id: id}}), do: short(id)
  defp selected_short_id(_snapshot), do: "new"

  defp session_state_label(snapshot) do
    case pending_review(snapshot) do
      nil -> selected_status(snapshot)
      _review -> "approval required"
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

  defp sandbox_health(%{sandbox: %{status: status}}), do: to_string(status)
  defp sandbox_health(%{"sandbox" => %{"status" => status}}), do: to_string(status)
  defp sandbox_health(_health), do: "unknown"

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

  defp progress_latest_title(summary) do
    summary
    |> json_field("latest_event", %{})
    |> first_json_field(["title", "phase", "kind"])
    |> present_string()
    |> case do
      nil -> "No progress events yet"
      value -> value
    end
  end

  defp progress_latest_detail(summary) do
    summary
    |> json_field("latest_event", %{})
    |> first_json_field(["detail", "status"])
    |> present_string()
  end

  defp progress_event_trail(summary) do
    summary
    |> first_json_field(["event_trail", "event_count"])
    |> present_string()
    |> case do
      nil -> "0 events"
      value -> value
    end
  end

  defp progress_facts(summary) do
    [
      %{label: "objective", value: json_field(summary, "objective_status", nil)},
      %{label: "action", value: json_field(summary, "objective_action", nil)},
      %{label: "error", value: objective_progress_error_label(summary)},
      %{label: "iteration", value: objective_progress_iteration_label(summary)},
      %{label: "open", value: json_field(summary, "objective_open_task_count", nil)},
      %{label: "done", value: json_field(summary, "objective_completed_task_count", nil)},
      %{label: "node", value: json_field(summary, "current_node", nil)},
      %{label: "child", value: json_field(summary, "current_child", nil)},
      %{label: "elapsed", value: summary |> json_field("elapsed_ms", nil) |> duration_label()},
      %{
        label: "remaining",
        value: summary |> json_field("remaining_ms", nil) |> duration_label()
      },
      %{label: "max", value: summary |> json_field("max_runtime_ms", nil) |> duration_label()},
      %{
        label: "child budget",
        value: summary |> json_field("selected_timeout_ms", nil) |> duration_label()
      }
    ]
    |> Enum.map(fn fact -> %{fact | value: present_string(fact.value)} end)
    |> Enum.reject(&is_nil(&1.value))
    |> Enum.take(6)
  end

  defp objective_progress_error_label(summary) do
    kind = summary |> json_field("objective_error_kind", nil) |> present_string()
    message = summary |> json_field("objective_error_message", nil) |> present_string()
    reason = summary |> json_field("objective_error_reason", nil) |> present_string()

    cond do
      kind && message && reason -> "#{kind}: #{message} (#{reason})"
      kind && message -> "#{kind}: #{message}"
      message && reason -> "#{message} (#{reason})"
      message -> message
      reason -> reason
      kind -> kind
      true -> nil
    end
  end

  defp objective_progress_iteration_label(summary) do
    current = json_field(summary, "objective_iteration", nil)
    max = json_field(summary, "objective_max_iterations", nil)

    cond do
      current && max -> "#{current}/#{max}"
      current -> current
      true -> nil
    end
  end

  defp duration_label(nil), do: nil
  defp duration_label(value) when is_binary(value), do: value

  defp duration_label(value) when is_integer(value) do
    cond do
      value < 1_000 -> "#{value}ms"
      value < 60_000 -> "#{Float.round(value / 1_000, 1)}s"
      true -> "#{Float.round(value / 60_000, 1)}m"
    end
  end

  defp duration_label(value), do: value

  defp message_blocked_next_actions(message) when is_map(message) do
    message
    |> Map.get(:content_json, %{})
    |> json_field("blocked_evidence", %{})
    |> blocked_next_actions()
  end

  defp message_blocked_next_actions(_message), do: []

  defp objective_loop_status(nil), do: "Not captured"

  defp objective_loop_status(loop) do
    loop
    |> first_json_field(["status", "objective_status"])
    |> present_string()
    |> case do
      nil -> "Loop captured"
      value -> value
    end
  end

  defp objective_loop_action(loop) do
    loop
    |> first_json_field(["action"])
    |> present_string()
  end

  defp objective_loop_facts(loop) do
    [
      %{label: "objective", value: loop |> first_json_field(["objective"])},
      %{label: "iterations", value: objective_loop_iteration_label(loop)},
      %{label: "error", value: objective_loop_error_label(loop)},
      %{label: "open", value: loop |> objective_loop_tasks() |> length()},
      %{
        label: "done",
        value: loop |> json_field("completed_tasks", []) |> List.wrap() |> length()
      }
    ]
    |> Enum.map(fn fact -> %{fact | value: present_string(fact.value)} end)
    |> Enum.reject(&is_nil(&1.value))
  end

  defp objective_loop_iteration_label(loop) do
    count = loop |> first_json_field(["iteration_count", "objective_iteration_count"])
    max = loop |> first_json_field(["max_iterations"])

    cond do
      is_nil(count) and is_nil(max) -> nil
      is_nil(max) -> count
      true -> "#{count || 0}/#{max}"
    end
  end

  defp objective_loop_error_label(loop) do
    kind = loop |> first_json_field(["latest_error_kind", "error_kind"]) |> present_string()

    message =
      loop |> first_json_field(["latest_error_message", "error_message"]) |> present_string()

    cond do
      kind && message -> "#{kind}: #{message}"
      message -> message
      kind -> kind
      true -> nil
    end
  end

  defp objective_loop_tasks(loop) do
    loop
    |> json_field("open_tasks", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.take(5)
  end

  defp objective_loop_task_text(task) do
    task
    |> first_json_field(["title", "reason", "id"])
    |> present_string()
    |> case do
      nil -> json_preview(task)
      value -> value
    end
  end

  defp objective_loop_budget_requests(loop) do
    loop
    |> json_field("budget_requests", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&pending_objective_loop_budget_request?/1)
    |> Enum.take(3)
  end

  defp pending_objective_loop_budget_request?(request) do
    json_field(request, "status", nil) in [nil, "pending", :pending, "waiting", :waiting]
  end

  defp objective_loop_budget_reason(loop) do
    loop
    |> objective_loop_budget_requests()
    |> List.first()
    |> case do
      nil ->
        nil

      request ->
        request
        |> first_json_field(["reason", "suggested_next_action"])
        |> present_string()
    end
  end

  defp objective_loop_review_requests(loop) do
    loop
    |> json_field("review_requests", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&pending_objective_loop_review_request?/1)
    |> Enum.take(3)
  end

  defp pending_objective_loop_review_request?(request) do
    json_field(request, "status", nil) in [nil, "pending", :pending, "waiting", :waiting]
  end

  defp objective_loop_review_reason(loop) do
    loop
    |> objective_loop_review_requests()
    |> List.first()
    |> case do
      nil ->
        nil

      request ->
        kind = request |> first_json_field(["kind"]) |> present_string()
        checkpoint = request |> first_json_field(["checkpoint"]) |> present_string()
        resume_key = request |> first_json_field(["resume_key"]) |> present_string()

        [kind || "review", checkpoint, resume_key]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" / ")
    end
  end

  defp contract_domain(nil), do: "Not captured"

  defp contract_domain(contract) do
    contract
    |> json_field("metadata", %{})
    |> first_json_field(["domain", "scenario", "workflow_profile"])
    |> present_string()
    |> case do
      nil -> "General objective"
      value -> value
    end
  end

  defp contract_profile(contract) do
    contract
    |> json_field("metadata", %{})
    |> first_json_field(["generation_profile", "profile", "intent"])
    |> present_string()
  end

  defp contract_evidence_required(contract) do
    contract
    |> json_field("metadata", %{})
    |> json_field("evidence_required", [])
    |> list_strings()
    |> Enum.take(5)
  end

  defp contract_requirements(contract) do
    contract
    |> json_field("requirements", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.take(6)
  end

  defp contract_requirement_id(requirement) do
    requirement
    |> first_json_field(["id", "name", "kind"])
    |> present_string()
    |> case do
      nil -> "requirement"
      value -> value
    end
  end

  defp contract_requirement_text(requirement) do
    requirement
    |> first_json_field(["description", "text", "title", "acceptance"])
    |> present_string()
    |> case do
      nil -> json_preview(requirement)
      value -> value
    end
  end

  defp blocked_status(nil), do: "Not blocked"

  defp blocked_status(evidence) do
    evidence
    |> first_json_field(["objective_status", "status", "blocking_reason"])
    |> present_string()
    |> case do
      nil -> "Blocked"
      value -> value
    end
  end

  defp blocked_current_node(evidence) do
    evidence
    |> first_json_field(["current_node", "node", "current_step"])
    |> present_string()
  end

  defp blocked_facts(evidence) do
    [
      %{label: "child", value: evidence |> first_json_field(["current_child", "child"])},
      %{
        label: "elapsed",
        value: evidence |> first_json_field(["elapsed_ms", "elapsed"]) |> duration_label()
      },
      %{
        label: "budget",
        value:
          evidence
          |> first_json_field([
            "remaining_ms",
            "remaining_budget_ms",
            "budget_ms",
            "max_runtime_ms"
          ])
          |> duration_label()
      },
      %{
        label: "event",
        value: evidence |> json_field("latest_event", %{}) |> json_field("title", nil)
      }
    ]
    |> Enum.map(fn fact -> %{fact | value: present_string(fact.value)} end)
    |> Enum.reject(&is_nil(&1.value))
  end

  defp blocked_next_actions(evidence) do
    evidence
    |> json_field("next_actions", [])
    |> list_strings()
    |> Enum.take(5)
  end

  defp first_json_field(map, keys) do
    Enum.find_value(keys, &json_field(map, &1, nil))
  end

  defp list_strings(value) when is_list(value) do
    value
    |> Enum.map(&present_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp list_strings(value) do
    case present_string(value) do
      nil -> []
      string -> [string]
    end
  end

  defp present_string(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present_string(nil), do: nil
  defp present_string(value) when is_atom(value), do: Atom.to_string(value)
  defp present_string(value) when is_integer(value), do: Integer.to_string(value)
  defp present_string(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)

  defp present_string(value) when is_map(value) or is_list(value), do: json_preview(value)
  defp present_string(value), do: to_string(value)

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

  defp pending_review(%{session: %{status: status}, review_requests: reviews})
       when status in ["running", "waiting", "review", "blocked"] do
    reviews
    |> Enum.filter(&(&1.status in ["pending", "waiting"]))
    |> Enum.sort_by(&pending_review_rank/1)
    |> List.first()
  end

  defp pending_review(_snapshot), do: nil

  defp pending_review_rank(%{id: id, resume_key: resume_key})
       when is_binary(id) and is_binary(resume_key) and id == resume_key,
       do: 0

  defp pending_review_rank(%{resume_key: resume_key})
       when is_binary(resume_key) and resume_key != "",
       do: 1

  defp pending_review_rank(%{checkpoint: checkpoint}) when is_binary(checkpoint), do: 2
  defp pending_review_rank(_review), do: 3

  defp pending_review_count(%{session: %{status: status}, review_requests: reviews})
       when status in ["running", "waiting", "review", "blocked"] do
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
    review = review_event(snapshot)
    events = Map.get(snapshot, :events, [])

    [
      %{
        state: "done",
        label: "01 objective",
        title: selected_title(snapshot),
        detail: "accepted - #{format_time(selected_started_at(snapshot))}"
      },
      workflow_stage_step(snapshot, "02 planning", :planning, events),
      workflow_stage_step(snapshot, "03 implementation", :implementation, events),
      workflow_stage_step(snapshot, "04 verification", :verification, events),
      workflow_stage_step(snapshot, "05 repair", :repair, events),
      %{
        state: if(review, do: "wait", else: "done"),
        label: "06 review",
        title: review_title(review),
        detail: selected_approval(snapshot) || "policy: local"
      }
    ]
  end

  defp workflow_stage_step(snapshot, label, stage, events) do
    event = first_workflow_stage_event(events, stage)

    %{
      state: workflow_stage_state(snapshot, stage, event),
      label: label,
      title: workflow_stage_title(stage, event),
      detail: workflow_stage_detail(snapshot, stage, event)
    }
  end

  defp first_workflow_stage_event(events, stage) do
    Enum.find(events, &workflow_stage_event?(&1, stage))
  end

  defp workflow_stage_event?(event, stage) do
    text = event_search_text(event)

    case stage do
      :planning ->
        text_contains_any?(text, [
          "proposal",
          "proposed",
          "validated",
          "workflow_compiled",
          "rlm_plan",
          "blueprint"
        ])

      :implementation ->
        text_contains_any?(text, [
          "node_started",
          "node_completed",
          "implement",
          "patch",
          "edit",
          "tool_call",
          "command_started",
          "command_completed"
        ])

      :verification ->
        text_contains_any?(text, [
          "verify",
          "verification",
          "compile_completed",
          "compiled",
          "test",
          "scorecard",
          "progress_gate"
        ])

      :repair ->
        text_contains_any?(text, ["repair", "retry", "correct", "ooda"])
    end
  end

  defp workflow_stage_state(_snapshot, _stage, event) when not is_nil(event) do
    case event_status(event) do
      status when status in ["failed", "error", :failed, :error] -> "error"
      status when status in ["running", :running] -> "live"
      status when status in ["waiting", "review", :waiting, :review] -> "wait"
      _status -> "done"
    end
  end

  defp workflow_stage_state(snapshot, :repair, nil) do
    case selected_status(snapshot) do
      status when status in ["running", :running] -> "wait"
      status when status in ["failed", :failed] -> "error"
      _status -> "done"
    end
  end

  defp workflow_stage_state(snapshot, _stage, nil) do
    case selected_status(snapshot) do
      status when status in ["running", :running] -> "wait"
      status when status in ["failed", :failed] -> "error"
      _status -> "done"
    end
  end

  defp workflow_stage_title(:planning, nil), do: "No workflow plan evidence yet."
  defp workflow_stage_title(:implementation, nil), do: "No implementation event evidence yet."
  defp workflow_stage_title(:verification, nil), do: "No verification evidence yet."
  defp workflow_stage_title(:repair, nil), do: "No repair requested."
  defp workflow_stage_title(_stage, event), do: current_event_title(event)

  defp workflow_stage_detail(snapshot, :repair, nil) do
    case selected_status(snapshot) do
      status when status in ["failed", :failed] -> "repair needed"
      status when status in ["running", :running] -> "waiting for verification"
      _status -> "not needed"
    end
  end

  defp workflow_stage_detail(_snapshot, _stage, nil), do: "waiting for persisted event"

  defp workflow_stage_detail(_snapshot, _stage, event) do
    event_phase(event) || event_kind(event) || event_status(event) || "persisted event"
  end

  defp event_search_text(event) do
    [
      event_kind(event),
      event_phase(event),
      event_status(event),
      Map.get(event, :title)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp text_contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp event_kind(event), do: Map.get(event, :kind)
  defp event_phase(event), do: Map.get(event, :phase)
  defp event_status(event), do: Map.get(event, :status)

  defp selected_started_at(%{session: %{started_at: started_at}}), do: started_at
  defp selected_started_at(_snapshot), do: nil

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
    |> Map.take([
      "path",
      "tool_name",
      "reason",
      "write_policy",
      "sandbox",
      "backend",
      "runtime",
      "network",
      "policy_escalations"
    ])
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
