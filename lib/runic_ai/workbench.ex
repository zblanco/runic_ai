defmodule RunicAI.Workbench do
  @moduledoc """
  Local workbench API shared by Phoenix LiveViews and future server packaging.

  The durable SQLite store remains the source of truth. This module provides
  bounded query projections and small PubSub invalidations for web surfaces.
  """

  alias RunicAI.Ids
  alias RunicAI.Agent.CapabilityResolver
  alias RunicAI.Coding.Review
  alias RunicAI.LLM.ModelCatalog
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.AgentSession
  alias RunicAI.Persistence.Schemas.ReviewRequest
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.Scorecard
  alias RunicAI.Persistence.Schemas.TerminalEvent
  alias RunicAI.Persistence.Schemas.ToolCall
  alias RunicAI.Persistence.Schemas.WorkflowRun
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Event, as: CoreEvent
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest, as: RuntimeReviewRequest
  alias RunicAI.Terminal.AgentRunner
  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.GraphPresenter
  alias RunicAI.Terminal.RLMRunner
  alias RunicAI.Workbench.StoreServer

  @topic "runic_ai:workbench"
  @task_supervisor RunicAI.Workbench.TaskSupervisor
  @sandbox_inventory_profiles [
    local_code: [
      backend: :just_bash,
      runtimes: [:bash],
      network: :disabled,
      stateful?: false,
      workspace: [mode: :copy_in, persist?: false],
      pool: [warm: 0, max: 1]
    ],
    lua: [
      backend: :lua,
      runtimes: [:lua],
      network: :disabled,
      stateful?: false,
      workspace: [mode: :copy_in, persist?: false],
      pool: [warm: 0, max: 1]
    ],
    docker: [
      backend: :docker,
      runtimes: [:bash, :python, :node, :elixir],
      network: :disabled,
      stateful?: true,
      workspace: [mode: :copy_in, persist?: true],
      pool: [warm: 0, max: 2]
    ],
    gvisor: [
      backend: :gvisor,
      runtimes: [:bash, :python, :node, :elixir],
      network: :disabled,
      stateful?: true,
      workspace: [mode: :copy_in, persist?: true],
      pool: [warm: 0, max: 2]
    ],
    vmsan: [
      backend: :vmsan,
      runtimes: [:bash, :python, :node, :elixir],
      network: :disabled,
      stateful?: true,
      workspace: [mode: :copy_in, persist?: true],
      pool: [warm: 0, max: 2]
    ],
    sprites: [
      backend: :sprites,
      runtimes: [:bash, :python, :node, :elixir],
      network: :restricted,
      stateful?: true,
      workspace: [mode: :copy_in, persist?: true],
      pool: [warm: 0, max: 2]
    ]
  ]

  @agent_choices %{"assistant" => :assistant, "standard" => :standard, "rlm" => :rlm}
  @approval_choices %{"safe" => :safe, "never" => :never, "ask" => :ask}
  @mode_choices %{"verify" => :verify, "patch" => :patch, "read_only" => :read_only}
  @write_policy_choices %{
    "docs_only" => :docs_only,
    "docs-only" => :docs_only,
    "workspace_review" => :workspace_review,
    "workspace-review" => :workspace_review,
    "none" => :none
  }
  @review_wait_poll_interval_ms 250
  @rlm_workspace_cues ~w(
    api app branch bug code codebase command compile compiler component config
    dependency deps diff docs ecto elixir endpoint error exception failing failure
    file files fix function git issue lib liveview log logs migration mix module
    patch phoenix pr repo repository route runic runicai schema sqlite stacktrace
    test tests tui warning warnings workspace
  )
  @param_atoms %{
    "action" => :action,
    "agent" => :agent,
    "approve" => :approve,
    "client" => :client,
    "cwd" => :cwd,
    "max_runtime_ms" => :max_runtime_ms,
    "mode" => :mode,
    "model" => :model,
    "model_id" => :model_id,
    "model_provider" => :model_provider,
    "max_objective_iterations" => :max_objective_iterations,
    "objective" => :objective,
    "profile" => :profile,
    "rewrite" => :rewrite,
    "run_id" => :run_id,
    "sandbox_backend" => :sandbox_backend,
    "sandbox_network" => :sandbox_network,
    "sandbox_pool_max" => :sandbox_pool_max,
    "sandbox_pool_warm" => :sandbox_pool_warm,
    "sandbox_profile" => :sandbox_profile,
    "sandbox_runtime" => :sandbox_runtime,
    "sandbox_stateful" => :sandbox_stateful,
    "session_id" => :session_id,
    "tool_config" => :tool_config,
    "toolsets" => :toolsets,
    "disabled_tools" => :disabled_tools,
    "write_policy" => :write_policy
  }

  @spec store() :: {:ok, Store.t()} | {:error, term()}
  def store, do: StoreServer.store()

  @spec store!() :: Store.t()
  def store!, do: StoreServer.store!()

  @spec health() :: map()
  def health do
    StoreServer.health()
    |> Map.put(:sandbox, sandbox_health())
  end

  @spec sandbox_status() :: map()
  def sandbox_status, do: sandbox_health()

  @spec config() :: keyword()
  def config, do: Application.get_env(:runic_ai, :workbench, [])

  defp sandbox_health do
    profiles = sandbox_inventory_profiles()
    manager = sandbox_manager_status()

    sandboxes =
      Map.new(profiles, fn {name, profile} ->
        direct = direct_sandbox_status(profile)
        managed = manager |> field(:sandboxes) |> field(name)

        {name, sandbox_inventory_status(profile, direct, managed)}
      end)

    %{
      status: if(map_size(sandboxes) == 0, do: :unavailable, else: :available),
      manager: Map.take(manager, [:status, :reason]),
      sandboxes: sandboxes
    }
  rescue
    exception -> %{status: :unavailable, reason: Exception.message(exception), sandboxes: %{}}
  end

  defp sandbox_inventory_profiles do
    (@sandbox_inventory_profiles ++ configured_sandbox_profiles())
    |> Enum.reduce(%{}, fn {name, profile_config}, acc ->
      case sandbox_inventory_profile_name(name) do
        nil ->
          acc

        name ->
          case RunicSandbox.Profile.from_named_config(name, profile_config) do
            {:ok, profile} -> Map.put(acc, profile.name, profile)
            {:error, _error} -> acc
          end
      end
    end)
  end

  defp sandbox_inventory_profile_name(name) when is_atom(name), do: name

  defp sandbox_inventory_profile_name(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp sandbox_inventory_profile_name(_name), do: nil

  defp configured_sandbox_profiles do
    :runic_ai
    |> Application.get_env(:sandbox, [])
    |> case do
      config when is_list(config) -> Keyword.get(config, :sandboxes, [])
      %{} = config -> Map.get(config, :sandboxes, Map.get(config, "sandboxes", []))
      _other -> []
    end
    |> case do
      profiles when is_list(profiles) -> profiles
      profiles when is_map(profiles) -> Map.to_list(profiles)
      _other -> []
    end
  end

  defp sandbox_manager_status do
    case Process.whereis(RunicAI.Sandbox) do
      nil ->
        %{status: :not_started, reason: :not_started, sandboxes: %{}}

      _pid ->
        case RunicSandbox.status(server: RunicAI.Sandbox) do
          {:ok, status} ->
            status
            |> sandbox_health_output()
            |> Map.put(:status, :running)

          {:error, error} ->
            %{status: :unavailable, reason: sandbox_error_reason(error), sandboxes: %{}}
        end
    end
  rescue
    exception -> %{status: :unavailable, reason: Exception.message(exception), sandboxes: %{}}
  end

  defp direct_sandbox_status(profile) do
    case RunicSandbox.status(profile: profile) do
      {:ok, status} -> sandbox_health_output(status)
      {:error, error} -> %{status: :unavailable, reason: sandbox_error_reason(error)}
    end
  rescue
    exception -> %{status: :unavailable, reason: Exception.message(exception)}
  end

  defp sandbox_inventory_status(profile, direct, managed) do
    profile_status = field(direct, :profile) || sandbox_profile_snapshot(profile)
    pool_status = field(managed, :pool_status) || empty_pool_status(profile)
    sessions = field(managed, :sessions) || []
    backend_health = direct |> field(:backends) |> List.wrap() |> List.first() || %{}
    available? = field(direct, :status) in [:available, "available"]
    active? = is_map(managed)
    warm_ready = field(pool_status, :ready) || 0
    busy = field(pool_status, :busy) || 0

    readiness =
      cond do
        warm_ready > 0 -> :ready
        busy > 0 -> :busy
        available? -> :cold
        true -> :unavailable
      end

    profile_status
    |> Map.merge(%{
      backend_health: backend_health,
      status: field(direct, :status) || :unknown,
      readiness: readiness,
      status_label: sandbox_readiness_label(readiness),
      status_detail: sandbox_readiness_detail(readiness, active?, pool_status, direct),
      active?: active?,
      selectable?: available?,
      reason: field(direct, :reason),
      pool_status: pool_status,
      sessions: sessions
    })
  end

  defp sandbox_profile_snapshot(%RunicSandbox.Profile{} = profile) do
    %{
      name: profile.name,
      backend: profile.backend,
      runtimes: profile.runtimes,
      isolation_level: profile.isolation_level,
      network: profile.policy.network,
      stateful?: profile.stateful?,
      workspace: profile.workspace,
      pool: profile.pool,
      metadata: profile.metadata
    }
    |> sandbox_health_output()
  end

  defp empty_pool_status(%RunicSandbox.Profile{} = profile) do
    %{
      warm: profile.pool.warm,
      max: profile.pool.max,
      total: 0,
      ready: 0,
      busy: 0,
      stale: 0,
      unhealthy: 0,
      available_capacity: profile.pool.max
    }
  end

  defp sandbox_readiness_label(:ready), do: "Ready"
  defp sandbox_readiness_label(:busy), do: "Busy"
  defp sandbox_readiness_label(:cold), do: "Starts on demand"
  defp sandbox_readiness_label(:unavailable), do: "Needs setup"

  defp sandbox_readiness_detail(:ready, true, pool_status, _direct) do
    ready = field(pool_status, :ready) || 0
    total = field(pool_status, :total) || 0
    "#{ready}/#{total} warm sessions ready"
  end

  defp sandbox_readiness_detail(:busy, true, pool_status, _direct) do
    busy = field(pool_status, :busy) || 0
    "All warm sessions are checked out (#{busy} busy)"
  end

  defp sandbox_readiness_detail(:cold, true, _pool_status, _direct),
    do: "Backend manager is running; this profile will open cold"

  defp sandbox_readiness_detail(:cold, false, _pool_status, _direct),
    do: "Backend is usable and will start when selected"

  defp sandbox_readiness_detail(:unavailable, _active?, _pool_status, direct) do
    case field(direct, :reason) do
      nil -> "Host requirements or credentials are missing"
      reason -> to_string(reason)
    end
  end

  defp sandbox_error_reason(%{message: message}) when is_binary(message), do: message
  defp sandbox_error_reason(error), do: error

  defp sandbox_health_output(%_struct{} = value),
    do: value |> Map.from_struct() |> sandbox_health_output()

  defp sandbox_health_output(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, sandbox_health_output(nested)} end)
  end

  defp sandbox_health_output(value) when is_list(value),
    do: Enum.map(value, &sandbox_health_output/1)

  defp sandbox_health_output(value), do: value

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(RunicAI.PubSub, @topic)

  @spec subscribe_session(String.t()) :: :ok | {:error, term()}
  def subscribe_session(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(RunicAI.PubSub, session_topic(session_id))
  end

  @spec broadcast_terminal_event(TerminalEvent.t()) :: :ok
  def broadcast_terminal_event(%TerminalEvent{} = event) do
    :ok = event |> core_event_from_persisted() |> broadcast_event()

    Phoenix.PubSub.broadcast(RunicAI.PubSub, @topic, {:workbench, :terminal_event, event})

    if is_binary(event.session_id) do
      Phoenix.PubSub.broadcast(
        RunicAI.PubSub,
        session_topic(event.session_id),
        {:workbench, :terminal_event, event}
      )
    end

    :ok
  end

  @spec broadcast_event(CoreEvent.t()) :: :ok
  def broadcast_event(%CoreEvent{} = event) do
    Phoenix.PubSub.broadcast(RunicAI.PubSub, @topic, {:workbench, :event, event})

    if is_binary(event.session_id) do
      Phoenix.PubSub.broadcast(
        RunicAI.PubSub,
        session_topic(event.session_id),
        {:workbench, :event, event}
      )
    end

    :ok
  end

  @spec record_event(map() | CoreEvent.t() | RunicAI.Terminal.Event.t()) ::
          {:ok, TerminalEvent.t()} | {:error, term()}
  def record_event(event) do
    with {:ok, %Store{} = store} <- store(),
         {:ok, %TerminalEvent{} = persisted} <- SQLite.record_terminal_event(store, event) do
      broadcast_terminal_event(persisted)
      {:ok, persisted}
    end
  end

  @spec record_terminal_event(map() | CoreEvent.t() | RunicAI.Terminal.Event.t()) ::
          {:ok, TerminalEvent.t()} | {:error, term()}
  def record_terminal_event(event), do: record_event(event)

  @spec recent_sessions(keyword()) :: [map()]
  def recent_sessions(opts \\ []) do
    store!()
    |> Queries.recent_sessions(opts)
    |> Enum.map(&session_view/1)
  end

  @spec session_snapshot(String.t()) :: map() | nil
  def session_snapshot(session_id) when is_binary(session_id) do
    store = store!()

    with %AgentSession{} = session <- Queries.get_session(store, session_id) do
      messages =
        store
        |> Queries.messages_for_session(session_id)
        |> visible_chat_messages()

      events = Queries.terminal_events_for_session(store, session_id)
      tools = Queries.tool_calls_for_session(store, session_id)
      runs = Queries.workflow_runs_for_session(store, session_id)
      reviews = Queries.review_requests(store, session_id)
      artifacts = Queries.artifacts_for_run(store, session_id)
      scorecards = Queries.scorecards_for_run(store, session_id)
      objective_loop = Queries.latest_objective_loop_state(store, session_id)
      event_views = Enum.map(events, &event_view/1)
      sandbox_execution_views = sandbox_execution_views(event_views)
      scorecard_views = Enum.map(scorecards, &scorecard_view/1)
      objective_contract = objective_contract_view(events, messages, scorecard_views)
      blocked_evidence = blocked_evidence_view(session, events, messages, scorecard_views)

      %{
        session: session_view(session),
        capability_profile: capability_profile_view(session, runs, events),
        messages: Enum.map(messages, &message_view/1),
        events: event_views,
        sandbox_executions: sandbox_execution_views,
        tool_calls: Enum.map(tools, &tool_call_view/1),
        runs: Enum.map(runs, &run_view/1),
        review_requests: Enum.map(reviews, &review_request_view/1),
        artifacts: Enum.map(artifacts, &artifact_view/1),
        scorecards: scorecard_views,
        objective_loop: objective_loop,
        objective_contract: objective_contract,
        blocked_evidence: blocked_evidence,
        plan_workflow_graph: plan_workflow_graph_view(event_views),
        progress_summary: progress_summary_view(event_views, blocked_evidence),
        metrics: %{
          messages: length(messages),
          events: length(events),
          sandbox_executions: length(sandbox_execution_views),
          tool_calls: length(tools),
          runs: length(runs),
          review_requests: length(reviews),
          artifacts: length(artifacts),
          scorecards: length(scorecards)
        }
      }
    end
  end

  @spec latest_objective_session(String.t()) :: RunicAI.Coding.RLM.ObjectiveSession.t() | nil
  def latest_objective_session(session_id) when is_binary(session_id) do
    store!()
    |> Queries.latest_objective_session(session_id)
  end

  @spec first_pending_review_session_id(keyword()) :: String.t() | nil
  def first_pending_review_session_id(opts \\ []) do
    limit = Keyword.get(opts, :limit, 40)
    store = store!()

    store
    |> Queries.recent_sessions(limit: limit)
    |> Enum.find_value(fn %AgentSession{id: session_id} ->
      if pending_review_requests(store, session_id) == [] do
        nil
      else
        session_id
      end
    end)
  end

  @spec start_agent_run(map()) :: {:ok, map()} | {:error, term()}
  def start_agent_run(params) when is_map(params) do
    with {:ok, launch} <- normalize_launch(params) do
      launch = Map.put(launch, :conversation_history, conversation_history(launch))

      with {:ok, %TerminalEvent{}} <- record_terminal_event(user_message_event(launch)),
           {:ok, %TerminalEvent{}} <- record_terminal_event(launch_event(launch)),
           {:ok, %TerminalEvent{}} <- record_terminal_event(capability_profile_event(launch)),
           {:ok, pid} <- start_agent_task(launch) do
        {:ok, %{session_id: launch.session_id, run_id: launch.run_id, pid: pid}}
      end
    end
  end

  @spec record_review_decision(String.t(), String.t(), map()) ::
          {:ok, TerminalEvent.t()} | {:error, term()}
  def record_review_decision(session_id, review_id, params)
      when is_binary(session_id) and is_binary(review_id) and is_map(params) do
    with {:ok, %ReviewRequest{} = review} <- get_review_request(session_id, review_id),
         :ok <- require_pending_review_decision(review),
         {:ok, decision} <- normalize_review_decision(params) do
      with {:ok, %TerminalEvent{} = event} <-
             record_terminal_event(review_decision_event(session_id, review, decision)) do
        maybe_start_objective_operator_resume(session_id, review, decision)
        {:ok, event}
      end
    end
  end

  defp require_pending_review_decision(%ReviewRequest{status: status})
       when status in ["pending", "waiting", "review"],
       do: :ok

  defp require_pending_review_decision(%ReviewRequest{}), do: {:error, :review_already_decided}

  defp normalize_launch(params) do
    cfg = config()

    objective =
      params
      |> value("objective")
      |> to_string()
      |> String.trim()

    with :ok <- require_objective(objective),
         {:ok, agent} <-
           choice(
             value(params, "agent"),
             @agent_choices,
             Keyword.get(cfg, :default_agent, :assistant)
           ),
         {:ok, approve} <-
           choice(
             value(params, "approve"),
             @approval_choices,
             Keyword.get(cfg, :default_approval, :safe)
           ),
         {:ok, mode} <-
           choice(value(params, "mode"), @mode_choices, Keyword.get(cfg, :default_mode, :verify)),
         {:ok, write_policy} <-
           choice(
             value(params, "write_policy"),
             @write_policy_choices,
             Keyword.get(cfg, :default_write_policy, default_write_policy(mode))
           ),
         {:ok, cwd} <- normalize_cwd(value(params, "cwd") || File.cwd!()),
         {:ok, {agent, agent_route}} <- {:ok, route_agent(agent, objective, mode)},
         {:ok, profile} <-
           normalize_profile(
             value(params, "profile") || Keyword.get(cfg, :default_profile, :local_workbench)
           ),
         {:ok, toolsets} <- normalize_list(value(params, "toolsets")),
         {:ok, disabled_tools} <- normalize_list(value(params, "disabled_tools")),
         {:ok, tool_config} <- normalize_tool_config(value(params, "tool_config")),
         {:ok, tool_config} <- normalize_sandbox_tool_config(tool_config, params),
         {:ok, capability_resolution} <-
           CapabilityResolver.resolve(cwd,
             agent: agent,
             mode: mode,
             profile: profile,
             toolsets: toolsets,
             disabled_tools: disabled_tools,
             tool_config: tool_config,
             approval: approve,
             write_policy: write_policy
           ),
         {:ok, max_runtime_ms} <-
           normalize_max_runtime(
             value(params, "max_runtime_ms") || Keyword.get(cfg, :max_runtime_ms, 300_000)
           ),
         {:ok, max_objective_iterations} <-
           normalize_max_objective_iterations(
             value(params, "max_objective_iterations") ||
               Keyword.get(cfg, :max_objective_iterations, 3)
           ) do
      session_id = value(params, "session_id") || Ids.unique("web-session")
      run_id = value(params, "run_id") || Ids.unique("#{agent}:web")
      capability_profile = capability_resolution.metadata
      sandbox = sandbox_launch_summary(tool_config, capability_profile)
      model = normalize_model_selection(params, cfg)

      {:ok,
       %{
         session_id: session_id,
         run_id: run_id,
         objective: objective,
         agent: agent,
         agent_route: agent_route,
         cwd: cwd,
         model: model,
         client: blank_to_nil(value(params, "client") || Keyword.get(cfg, :default_client)),
         approve: approve,
         mode: mode,
         write_policy: write_policy,
         profile: profile,
         toolsets: toolsets,
         disabled_tools: disabled_tools,
         tool_config: tool_config,
         sandbox: sandbox,
         capability_profile: capability_profile,
         run_fun: Keyword.get(cfg, :run_fun),
         max_runtime_ms: max_runtime_ms,
         max_objective_iterations: max_objective_iterations
       }}
    end
  end

  defp route_agent(:rlm, _objective, :patch), do: {:rlm, nil}

  defp route_agent(:rlm, objective, _mode) do
    if workspace_objective?(objective) do
      {:rlm, nil}
    else
      {:assistant,
       %{
         requested_agent: :rlm,
         routed_agent: :assistant,
         route_reason: :non_workspace_rlm_objective
       }}
    end
  end

  defp route_agent(:assistant, objective, _mode) do
    if local_command_objective?(objective) do
      {:standard,
       %{
         requested_agent: :assistant,
         routed_agent: :standard,
         route_reason: :local_command_objective
       }}
    else
      {:assistant, nil}
    end
  end

  defp route_agent(agent, _objective, _mode), do: {agent, nil}

  defp local_command_objective?(objective) when is_binary(objective) do
    objective = String.downcase(objective)

    (String.contains?(objective, "command") or
       String.contains?(objective, "terminal") or
       String.contains?(objective, "shell") or
       String.contains?(objective, "cli")) and
      Regex.match?(~r/(^|[^a-z0-9_])(run|execute|invoke|call)([^a-z0-9_]|$)/, objective)
  end

  defp workspace_objective?(objective) when is_binary(objective) do
    objective = String.downcase(objective)

    Enum.any?(@rlm_workspace_cues, fn cue ->
      Regex.match?(~r/(^|[^a-z0-9_])#{Regex.escape(cue)}([^a-z0-9_]|$)/, objective)
    end)
  end

  defp start_agent_task(launch) do
    fun = fn -> run_agent(launch) end

    case Process.whereis(@task_supervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(@task_supervisor, fun)
    end
  end

  defp run_agent(launch) do
    args = cli_args(launch)

    with {:ok, %CliOptions{} = options} <- CliOptions.parse(args),
         {:ok, %Store{} = store} <- store() do
      runner_opts =
        [
          persistence: store,
          output_fun: fn _line -> :ok end,
          input_fun: fn _prompt -> "d\n" end,
          run_id: launch.run_id,
          conversation_history: Map.get(launch, :conversation_history, [])
        ]
        |> maybe_put(:run_fun, launch.run_fun)
        |> maybe_put(:review_decider, browser_review_decider(launch))

      AgentRunner.run(options, runner_opts)
    end
  end

  defp maybe_start_objective_operator_resume(session_id, %ReviewRequest{} = review, decision) do
    with %RunicAI.Coding.RLM.ObjectiveSession{} = session <- latest_objective_session(session_id),
         {:ok, resume_kind} <- objective_resume_kind(session, review),
         {:ok, %ReviewDecision{} = review_decision} <-
           objective_operator_decision(review, decision, resume_kind),
         {:ok, pid} <-
           start_objective_resume_task(session_id, review, session, review_decision, resume_kind) do
      {:ok, pid}
    else
      _other -> :ok
    end
  end

  defp objective_resume_kind(
         %RunicAI.Coding.RLM.ObjectiveSession{} = session,
         %ReviewRequest{} = review
       ) do
    cond do
      objective_review_request?(session, review) -> {:ok, :review}
      objective_budget_request?(session, review) -> {:ok, :budget}
      true -> {:error, :not_objective_resume}
    end
  end

  defp objective_review_request?(
         %RunicAI.Coding.RLM.ObjectiveSession{} = session,
         %ReviewRequest{} = review
       ) do
    session.status == :needs_review_approval and
      Enum.any?(session.review_requests, fn request ->
        field(request, :resume_key) in [review.resume_key, review.id]
      end)
  end

  defp objective_budget_request?(
         %RunicAI.Coding.RLM.ObjectiveSession{} = session,
         %ReviewRequest{} = review
       ) do
    session.status == :needs_budget_approval and
      Enum.any?(session.budget_requests, fn request ->
        key = field(request, :resume_key) || field(request, :id)
        key in [review.resume_key, review.id]
      end)
  end

  defp objective_operator_decision(%ReviewRequest{} = review, decision, resume_kind) do
    status =
      case Map.get(decision, :decision_status) || Map.get(decision, "decision_status") do
        status when status in [:approved, "approved"] -> :approved
        status when status in [:edited, "edited"] -> :edited
        status when status in [:denied, "denied", :rejected, "rejected"] -> :rejected
        status when status in [:cancelled, "cancelled"] -> :cancelled
        _other -> nil
      end

    if status do
      ReviewDecision.new(review.resume_key || review.id, status,
        edited_value: Map.get(decision, :edited_value) || Map.get(decision, "edited_value"),
        actor: :workbench,
        metadata:
          %{
            source: :objective_loop_operator_decision,
            resume_kind: resume_kind,
            additional_iterations:
              Map.get(decision, :additional_iterations) ||
                Map.get(decision, "additional_iterations"),
            additional_runtime_ms:
              Map.get(decision, :additional_runtime_ms) ||
                Map.get(decision, "additional_runtime_ms"),
            approved_runtime_ms:
              Map.get(decision, :approved_runtime_ms) ||
                Map.get(decision, "approved_runtime_ms"),
            max_runtime_ms:
              Map.get(decision, :max_runtime_ms) ||
                Map.get(decision, "max_runtime_ms")
          }
          |> compact_map()
      )
    else
      {:error, :unsupported_objective_review_decision}
    end
  end

  defp start_objective_resume_task(
         session_id,
         %ReviewRequest{} = review,
         %RunicAI.Coding.RLM.ObjectiveSession{} = session,
         %ReviewDecision{} = decision,
         resume_kind
       ) do
    fun = fn ->
      resume_objective_after_operator_decision(session_id, review, session, decision, resume_kind)
    end

    case Process.whereis(@task_supervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(@task_supervisor, fun)
    end
  end

  defp resume_objective_after_operator_decision(
         session_id,
         %ReviewRequest{} = review,
         session,
         decision,
         resume_kind
       ) do
    cfg = config()
    cwd = objective_resume_cwd(session_id)

    opts = [
      cwd: cwd,
      session_id: session_id,
      run_id: review.workflow_run_id || session.id,
      run_fun: Keyword.get(cfg, :run_fun),
      max_runtime_ms: Keyword.get(cfg, :max_runtime_ms, 300_000),
      event_sink: fn event ->
        _ = record_terminal_event(event)
        :ok
      end
    ]

    case resume_kind do
      :budget -> RLMRunner.resume_after_budget(session, decision, opts)
      :review -> RLMRunner.resume_after_review(session, decision, opts)
    end
  end

  defp objective_resume_cwd(session_id) do
    case Queries.get_session(store!(), session_id) do
      %AgentSession{workspace_root: cwd} when is_binary(cwd) and cwd != "" -> cwd
      _other -> File.cwd!()
    end
  end

  defp browser_review_decider(%{approve: approve} = launch) when approve in [:ask, :safe] do
    fn %RuntimeReviewRequest{} = request, context ->
      if approve == :safe and safe_review?(request) do
        {:ok, Review.allow(request, reason: "review approved by browser safe policy")}
      else
        request = ensure_review_id(request)
        :ok = subscribe_session(launch.session_id)
        _ = ensure_browser_review_request(launch, request, context)

        wait_for_browser_review_decision(
          launch.session_id,
          request,
          launch.max_runtime_ms,
          System.monotonic_time(:millisecond)
        )
      end
    end
  end

  defp browser_review_decider(_launch), do: nil

  defp safe_review?(%RuntimeReviewRequest{} = request) do
    request.metadata[:safe?] in [true, "true"] or
      request.details[:safe?] in [true, "true"] or
      request.details[:risk] in [:low, "low"]
  end

  defp wait_for_browser_review_decision(
         session_id,
         %RuntimeReviewRequest{} = request,
         timeout_ms,
         started_at
       ) do
    case persisted_browser_review_decision(session_id, request) do
      {:ok, %ReviewDecision{} = decision} ->
        {:ok, decision}

      :pending ->
        remaining_ms = remaining_timeout(timeout_ms, started_at)

        if remaining_ms <= 0 do
          {:ok, Review.final_stop(request, reason: "browser review timed out")}
        else
          receive do
            {:workbench, :terminal_event, %TerminalEvent{} = event} ->
              case browser_review_decision(event, request) do
                {:ok, %ReviewDecision{} = decision} ->
                  {:ok, decision}

                :ignore ->
                  wait_for_browser_review_decision(session_id, request, timeout_ms, started_at)
              end
          after
            min(@review_wait_poll_interval_ms, remaining_ms) ->
              wait_for_browser_review_decision(session_id, request, timeout_ms, started_at)
          end
        end
    end
  end

  defp persisted_browser_review_decision(session_id, %RuntimeReviewRequest{} = request) do
    case get_review_request(session_id, request.resume_key) do
      {:ok, %ReviewRequest{} = review} ->
        review
        |> persisted_review_decision_payload()
        |> case do
          nil -> :pending
          decision -> decision_from_event(request, decision)
        end

      {:error, :review_not_found} ->
        :pending
    end
  end

  defp persisted_review_decision_payload(%ReviewRequest{decision_json: decision})
       when is_map(decision) and map_size(decision) > 0,
       do: decision

  defp persisted_review_decision_payload(%ReviewRequest{status: status})
       when status in ["approved", "denied", "cancelled"],
       do: %{"decision" => status, "status" => status}

  defp persisted_review_decision_payload(%ReviewRequest{}), do: nil

  defp remaining_timeout(timeout_ms, started_at)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    max(timeout_ms - (System.monotonic_time(:millisecond) - started_at), 0)
  end

  defp remaining_timeout(_timeout_ms, _started_at), do: 0

  defp ensure_review_id(%RuntimeReviewRequest{resume_key: resume_key} = request)
       when is_binary(resume_key) and resume_key != "",
       do: request

  defp ensure_review_id(%RuntimeReviewRequest{} = request) do
    %{request | resume_key: Ids.unique("review")}
  end

  defp ensure_browser_review_request(launch, %RuntimeReviewRequest{} = request, context) do
    if get_review_request(launch.session_id, request.resume_key) == {:error, :review_not_found} do
      request
      |> Event.from_review_request(session_id: launch.session_id, agent: launch.agent)
      |> Map.update!(:data, fn data ->
        Map.merge(data, %{
          run_id: launch.run_id,
          id: request.resume_key,
          status: :review,
          data: %{
            id: request.resume_key,
            kind: request.kind,
            checkpoint: request.checkpoint,
            resume_key: request.resume_key,
            options: request.options,
            details: request.details,
            metadata: request.metadata,
            context: Map.take(context, [:workspace, :params])
          }
        })
      end)
      |> record_terminal_event()
    else
      :ok
    end

    :ok
  end

  defp browser_review_decision(
         %TerminalEvent{kind: "hitl", phase: "review_decision", data_json: data},
         %RuntimeReviewRequest{} = request
       ) do
    decision = field(data, :decision) || %{}

    if field(data, :id) == request.resume_key or field(data, :resume_key) == request.resume_key do
      decision_from_event(request, decision)
    else
      :ignore
    end
  end

  defp browser_review_decision(_event, _request), do: :ignore

  defp decision_from_event(%RuntimeReviewRequest{} = request, decision) do
    metadata = browser_review_decision_metadata(decision)

    case field(decision, :decision) || field(decision, :status) do
      action when action in ["approve", :approve, "approved", :approved] ->
        {:ok, Review.allow(request, reason: "approved in browser", metadata: metadata)}

      action
      when action in ["deny", :deny, "denied", :denied, "reject", :reject, "rejected", :rejected] ->
        {:ok, Review.deny(request, reason: "denied in browser", metadata: metadata)}

      action when action in ["stop", :stop, "cancelled", :cancelled, "cancel", :cancel] ->
        {:ok, Review.final_stop(request, reason: "stopped in browser", metadata: metadata)}

      action when action in ["rewrite", :rewrite, "edited", :edited] ->
        {:ok,
         Review.rewrite(request, field(decision, :edited_value) || "",
           reason: "rewritten in browser",
           metadata: metadata
         )}

      _other ->
        :ignore
    end
  end

  defp browser_review_decision_metadata(decision) do
    [:additional_iterations, :additional_runtime_ms, :approved_runtime_ms, :max_runtime_ms]
    |> Enum.reduce(%{}, fn key, metadata ->
      case field(decision, key) do
        value when value in [nil, ""] -> metadata
        value -> Map.put(metadata, key, value)
      end
    end)
  end

  defp get_review_request(session_id, review_id) do
    store = store!()

    store
    |> Queries.review_requests(session_id)
    |> Enum.find(&(&1.id == review_id))
    |> case do
      nil -> {:error, :review_not_found}
      %ReviewRequest{} = review -> {:ok, review}
    end
  end

  defp pending_review_requests(store, session_id) do
    store
    |> Queries.review_requests(session_id)
    |> Enum.filter(&(&1.status in ["pending", "waiting"]))
  end

  defp normalize_review_decision(params) do
    action = params |> value("action") |> to_string()
    rewrite = params |> value("rewrite") |> to_string() |> String.trim()
    budget_metadata = review_budget_metadata(params)

    case action do
      "approve" ->
        {:ok,
         Map.merge(
           %{
             action: "approve",
             status: :ok,
             decision_status: "approved"
           },
           budget_metadata
         )}

      "deny" ->
        {:ok, %{action: "deny", status: :blocked, decision_status: "denied"}}

      "stop" ->
        {:ok, %{action: "stop", status: :blocked, decision_status: "cancelled"}}

      "rewrite" when rewrite != "" ->
        {:ok,
         Map.merge(
           %{
             action: "rewrite",
             status: :ok,
             decision_status: "edited",
             edited_value: rewrite
           },
           budget_metadata
         )}

      "rewrite" ->
        {:error, :empty_rewrite}

      _other ->
        {:error, :invalid_review_decision}
    end
  end

  defp review_budget_metadata(params) do
    %{
      additional_iterations: value(params, "additional_iterations"),
      additional_runtime_ms: value(params, "additional_runtime_ms"),
      approved_runtime_ms: value(params, "approved_runtime_ms"),
      max_runtime_ms: value(params, "max_runtime_ms")
    }
    |> compact_map()
  end

  defp review_decision_event(session_id, %ReviewRequest{} = review, decision) do
    decided_at = DateTime.utc_now()

    %{
      id: Ids.unique("terminal_event"),
      session_id: session_id,
      run_id: review.workflow_run_id || session_id,
      agent: :assistant,
      kind: :hitl,
      phase: :review_decision,
      status: decision.status,
      title: "Review #{decision.action}",
      detail: review_decision_detail(review, decision),
      data_json: %{
        id: review.id,
        run_id: review.workflow_run_id || session_id,
        kind: review.kind,
        checkpoint: review.checkpoint,
        resume_key: review.resume_key,
        decision:
          %{
            decision: decision.action,
            status: decision.decision_status,
            edited_value: Map.get(decision, :edited_value),
            additional_iterations: Map.get(decision, :additional_iterations),
            additional_runtime_ms: Map.get(decision, :additional_runtime_ms),
            approved_runtime_ms: Map.get(decision, :approved_runtime_ms),
            max_runtime_ms: Map.get(decision, :max_runtime_ms),
            decided_at: decided_at
          }
          |> compact_map()
      },
      at: decided_at
    }
  end

  defp review_decision_detail(%ReviewRequest{} = review, decision) do
    case Map.get(decision, :edited_value) do
      nil -> "review #{review.id} #{decision.action}"
      edited -> "review #{review.id} rewrite: #{String.slice(edited, 0, 120)}"
    end
  end

  defp cli_args(launch) do
    [
      "--agent",
      Atom.to_string(launch.agent),
      "--cwd",
      launch.cwd,
      "--mode",
      mode_arg(launch.mode),
      "--profile",
      to_string(launch.profile),
      "--approve",
      Atom.to_string(launch.approve),
      "--write-policy",
      write_policy_arg(launch.write_policy),
      "--session-id",
      launch.session_id,
      "--renderer",
      "text",
      "--color",
      "never",
      "--progress",
      "off",
      "--persistence",
      "none",
      "--max-runtime-ms",
      Integer.to_string(launch.max_runtime_ms)
    ]
    |> append_objective_loop_args(launch)
    |> maybe_append_list("--toolsets", launch.toolsets)
    |> append_repeated("--disable-tool", launch.disabled_tools)
    |> append_tool_config(launch.tool_config)
    |> maybe_append("--model", launch.model)
    |> maybe_append("--client", launch.client)
    |> maybe_append("--output", inferred_output_path(launch.objective))
    |> Kernel.++([launch.objective])
  end

  defp user_message_event(launch) do
    %{
      id: Ids.unique("terminal_event"),
      session_id: launch.session_id,
      run_id: launch.run_id,
      agent: launch.agent,
      kind: :message,
      phase: :user,
      status: :ok,
      title: "User request",
      detail: launch.objective,
      data_json:
        %{
          run_id: launch.run_id,
          role: "user",
          message_kind: "objective",
          content: launch.objective,
          objective: launch.objective,
          conversation_id: "conversation:#{launch.session_id}",
          presentation_group_id: launch.run_id,
          cwd: launch.cwd,
          model: launch.model
        }
        |> put_agent_route(launch),
      at: DateTime.utc_now()
    }
  end

  defp launch_event(launch) do
    %{
      id: Ids.unique("terminal_event"),
      session_id: launch.session_id,
      run_id: launch.run_id,
      agent: launch.agent,
      kind: :status,
      phase: :session,
      status: :running,
      title: "Workbench run queued",
      detail: launch.objective,
      data_json:
        %{
          run_id: launch.run_id,
          session_id: launch.session_id,
          cwd: launch.cwd,
          objective: launch.objective,
          model: launch.model,
          client: launch.client,
          approve: launch.approve,
          mode: launch.mode,
          write_policy: launch.write_policy,
          profile: launch.profile,
          toolsets: launch.toolsets,
          disabled_tools: launch.disabled_tools,
          tool_config: launch.tool_config,
          sandbox: launch.sandbox,
          capability_profile: launch.capability_profile,
          max_runtime_ms: launch.max_runtime_ms,
          max_objective_iterations: launch.max_objective_iterations,
          trigger: "browser"
        }
        |> put_agent_route(launch),
      at: DateTime.utc_now()
    }
  end

  defp capability_profile_event(launch) do
    %{
      id: Ids.unique("terminal_event"),
      session_id: launch.session_id,
      run_id: launch.run_id,
      agent: launch.agent,
      kind: :status,
      phase: :capability_profile_updated,
      status: :ok,
      title: "Capability profile resolved",
      detail: to_string(launch.profile),
      data_json: %{
        run_id: launch.run_id,
        session_id: launch.session_id,
        profile: launch.profile,
        toolsets: launch.toolsets,
        disabled_tools: launch.disabled_tools,
        sandbox: launch.sandbox,
        capability_profile: launch.capability_profile,
        trigger: "browser"
      },
      at: DateTime.utc_now()
    }
  end

  defp put_agent_route(data, %{agent_route: nil}), do: data
  defp put_agent_route(data, %{agent_route: route}) when is_map(route), do: Map.merge(data, route)
  defp put_agent_route(data, _launch), do: data

  defp session_view(%AgentSession{} = session) do
    metadata = session.metadata_json || %{}

    %{
      id: session.id,
      title: first_present(session.objective, session.id),
      objective: session.objective,
      agent: session.agent_kind || "assistant",
      workspace_root: session.workspace_root,
      model: session.model,
      status: session.status || "running",
      started_at: session.started_at,
      completed_at: session.completed_at,
      failed_at: session.failed_at,
      metadata: metadata,
      capability_profile: field(metadata, :capability_profile),
      short_id: short_id(session.id)
    }
  end

  defp capability_profile_view(%AgentSession{} = session, runs, events) do
    metadata = session.metadata_json || %{}

    field(metadata, :capability_profile) ||
      Enum.find_value(runs, fn run -> field(run.metadata_json || %{}, :capability_profile) end) ||
      Enum.find_value(events, fn event -> field(event.data_json || %{}, :capability_profile) end)
  end

  defp message_view(%AgentMessage{} = message) do
    %{
      id: message.id,
      role: message.role,
      kind: message.message_kind,
      source_step: message.source_step,
      workflow_node: message.workflow_node,
      content: message.content || "",
      content_json: message.content_json || %{},
      stream_complete: message.stream_complete,
      transient: message.transient,
      created_at: message.created_at
    }
  end

  defp visible_chat_messages(messages) do
    substantive =
      Enum.reject(messages, fn message ->
        message.transient or assistant_summary_message?(message)
      end)

    case substantive do
      [] -> messages
      visible -> dedupe_visible_chat_messages(visible)
    end
  end

  defp dedupe_visible_chat_messages(messages) do
    messages
    |> Enum.reverse()
    |> Enum.uniq_by(fn message ->
      {
        message.presentation_group_id || message.session_id,
        message.role,
        message.message_kind,
        normalized_message_content(message.content)
      }
    end)
    |> Enum.reverse()
  end

  defp normalized_message_content(content) do
    content
    |> to_string()
    |> String.trim()
  end

  defp assistant_summary_message?(%AgentMessage{role: "assistant", message_kind: "summary"}),
    do: true

  defp assistant_summary_message?(%AgentMessage{}), do: false

  defp core_event_from_persisted(%TerminalEvent{} = event) do
    CoreEvent.new!(event.kind,
      id: event.id,
      at: event.at,
      session_id: event.session_id,
      run_id: event.run_id,
      agent: event.agent,
      phase: event.phase,
      status: event.status,
      title: event.title,
      detail: event.detail,
      data: event.data_json || %{}
    )
  end

  defp event_view(%TerminalEvent{} = event) do
    %{
      id: event.id,
      session_id: event.session_id,
      run_id: event.run_id,
      sequence: event.sequence,
      at: event.at,
      agent: event.agent,
      kind: event.kind,
      phase: event.phase,
      status: event.status,
      title: event.title,
      detail: event.detail,
      data: event.data_json || %{}
    }
  end

  defp event_view(_event), do: nil

  defp sandbox_execution_views(events) do
    events
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&sandbox_event?/1)
    |> Enum.map(&sandbox_execution_view/1)
  end

  defp sandbox_event?(event) do
    data = field(event, :data) || %{}
    phase = event |> field(:phase) |> to_string()
    trace_kind = data |> field(:trace_kind) |> to_string()

    phase == "sandbox" or String.starts_with?(trace_kind, "coding_sandbox_")
  end

  defp sandbox_execution_view(event) do
    data = field(event, :data) || %{}
    metadata = field(data, :metadata) || %{}
    input = field(data, :input) || field(metadata, :input) || %{}
    output = field(data, :output) || %{}

    %{
      id: field(event, :id),
      run_id: field(event, :run_id),
      sequence: field(event, :sequence),
      at: field(event, :at),
      status: field(event, :status),
      phase: field(event, :phase),
      trace_kind: field(data, :trace_kind),
      title: field(event, :title),
      detail: field(event, :detail),
      sandbox: field(metadata, :sandbox) || field(input, :sandbox),
      runtime: field(metadata, :runtime) || field(input, :runtime),
      network: field(metadata, :network) || field(input, :network),
      backend: field(output, :backend) || field(metadata, :backend),
      isolation_level: field(output, :isolation_level) || field(metadata, :isolation_level),
      exit_status: field(output, :exit_status),
      duration_ms: field(output, :duration_ms),
      output_bytes: field(output, :output_bytes),
      files_changed: field(output, :files_changed) || [],
      artifacts: field(output, :artifacts) || [],
      diagnostics: field(output, :diagnostics) || []
    }
    |> compact_map()
  end

  defp plan_workflow_graph_view(events) do
    events
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      case compile_event_graph_summary(event) do
        nil -> nil
        graph -> workflow_graph_view(event, graph)
      end
    end)
  end

  defp compile_event_graph_summary(event) do
    phase = event |> field(:phase) |> to_string()

    if phase in ["compile_completed", "compiled"] do
      data = field(event, :data) || %{}
      compiled = field(data, :compiled) || field(field(data, :data) || %{}, :compiled) || %{}

      field(data, :graph_summary) ||
        field(compiled, :graph_summary) ||
        field(field(compiled, :runic) || %{}, :graph_summary)
    end
  end

  defp workflow_graph_view(event, graph) when is_map(graph) do
    mermaid = graph_mermaid(graph) || GraphPresenter.to_mermaid(graph)

    %{
      title: "Compiled workflow graph",
      mermaid: mermaid,
      fallback: GraphPresenter.adjacency_text(graph),
      metadata: %{
        run_id: field(event, :run_id),
        phase: field(event, :phase),
        sequence: field(event, :sequence)
      },
      nodes: graph_nodes(graph),
      edges: graph_edges(graph),
      source_hash: hash_source(mermaid || inspect(graph))
    }
  end

  defp workflow_graph_view(_event, _graph), do: nil

  defp graph_mermaid(graph) do
    graph
    |> field(:runic)
    |> field(:serializers)
    |> field(:mermaid)
    |> case do
      source when is_binary(source) and source != "" -> source
      _other -> nil
    end
  end

  defp graph_nodes(graph) do
    runic = field(graph, :runic) || %{}

    (field(graph, :nodes) || field(graph, :components) || field(runic, :native_nodes) || [])
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.map(fn {node, index} -> graph_node(node, index) end)
  end

  defp graph_node(node, index) when is_map(node) do
    id = field(node, :name) || field(node, :id) || "node_#{index}"

    %{
      id: to_string(id),
      label: to_string(field(node, :label) || field(node, :title) || field(node, :name) || id),
      kind: stringify(field(node, :kind) || field(node, :type)),
      status: stringify(field(node, :status))
    }
  end

  defp graph_node(node, index) do
    id = stringify(node) || "node_#{index}"
    %{id: id, label: id, kind: nil, status: nil}
  end

  defp graph_edges(graph) do
    runic = field(graph, :runic) || %{}

    (field(graph, :edges) || field(runic, :edgelist) || [])
    |> List.wrap()
    |> Enum.map(&graph_edge/1)
    |> Enum.reject(&is_nil/1)
  end

  defp graph_edge(edge) when is_map(edge) do
    from = field(edge, :from) || field(edge, :source)
    to = field(edge, :to) || field(edge, :target)

    if is_nil(from) or is_nil(to) do
      nil
    else
      %{from: to_string(from), to: to_string(to), label: stringify(field(edge, :label))}
    end
  end

  defp graph_edge(_edge), do: nil

  defp progress_summary_view(events, blocked_evidence) do
    events = Enum.reject(events, &is_nil/1)
    latest = latest_progress_event(events)
    latest_node = latest_progress_field_event(events, [:node_id, :node, :current_node])

    latest_child =
      latest_progress_field_event(events, [:child_id, :child_agent_id, :current_child])

    latest_objective =
      latest_progress_field_event(events, [
        :objective_session_id,
        :objective,
        :current_iteration,
        :iteration_count,
        :objective_iteration_count,
        :objective_session,
        :objective_session_state,
        :objective_decision
      ])

    latest_elapsed = latest_progress_field_event(events, [:elapsed_ms])
    latest_max_runtime = latest_progress_field_event(events, [:max_runtime_ms])
    latest_remaining = latest_progress_field_event(events, [:remaining_ms, :remaining_runtime_ms])
    latest_deadline = latest_progress_field_event(events, [:run_deadline_ms])
    latest_timeout = latest_progress_field_event(events, [:selected_timeout_ms])

    %{
      event_count: length(events),
      latest_event: latest,
      current_node:
        field(blocked_evidence || %{}, :current_node) ||
          progress_event_field(latest_node, :node_id) ||
          progress_event_field(latest_node, :node) ||
          progress_event_field(latest_node, :current_node),
      current_child:
        field(blocked_evidence || %{}, :current_child) ||
          progress_event_field(latest_child, :child_id) ||
          progress_event_field(latest_child, :child_agent_id) ||
          progress_event_field(latest_child, :current_child),
      objective:
        progress_event_field(latest_objective, :objective) ||
          objective_session_field(latest_objective, :objective),
      objective_status:
        objective_session_field(latest_objective, :status) ||
          progress_event_field(latest_objective, :status),
      objective_action:
        objective_decision_field(latest_objective, :action) ||
          progress_event_field(latest_objective, :action),
      objective_iteration:
        progress_event_field(latest_objective, :current_iteration) ||
          progress_event_field(latest_objective, :iteration_count) ||
          progress_event_field(latest_objective, :objective_iteration_count) ||
          objective_session_field(latest_objective, :iteration_count),
      objective_max_iterations:
        progress_event_field(latest_objective, :max_iterations) ||
          objective_session_field(latest_objective, :max_iterations),
      objective_open_task_count: progress_task_count(latest_objective, :open_tasks),
      objective_completed_task_count: progress_task_count(latest_objective, :completed_tasks),
      objective_error_kind: objective_error_field(latest_objective, :kind),
      objective_error_message: objective_error_field(latest_objective, :message),
      objective_error_reason:
        objective_error_field(latest_objective, :reason_message) ||
          objective_error_field(latest_objective, :reason),
      elapsed_ms:
        field(blocked_evidence || %{}, :elapsed_ms) ||
          progress_event_field(latest_elapsed, :elapsed_ms),
      max_runtime_ms:
        field(blocked_evidence || %{}, :max_runtime_ms) ||
          progress_event_field(latest_max_runtime, :max_runtime_ms),
      remaining_ms:
        field(blocked_evidence || %{}, :remaining_ms) ||
          progress_event_field(latest_remaining, :remaining_ms) ||
          progress_event_field(latest_remaining, :remaining_runtime_ms),
      run_deadline_ms: progress_event_field(latest_deadline, :run_deadline_ms),
      selected_timeout_ms: progress_event_field(latest_timeout, :selected_timeout_ms),
      event_trail: "#{length(events)} persisted events"
    }
    |> compact_map()
  end

  defp latest_progress_event(events) do
    events
    |> Enum.reverse()
    |> Enum.find(&progress_event?/1) ||
      List.last(events)
  end

  defp progress_event?(event) do
    kind = event |> field(:kind) |> to_string()
    phase = event |> field(:phase) |> to_string()

    kind in ["rlm_plan", "rlm_node", "repair", "summary", "hitl", "status"] or
      String.contains?(kind, "coding_command") or
      String.contains?(kind, "coding_process") or
      String.contains?(phase, "proposal") or
      String.contains?(phase, "node") or
      String.contains?(phase, "child") or
      String.contains?(phase, "budget") or
      String.contains?(phase, "objective_loop") or
      String.contains?(phase, "repair") or
      String.contains?(phase, "scorecard")
  end

  defp latest_progress_field_event(events, keys) do
    events
    |> Enum.reverse()
    |> Enum.find(fn event ->
      Enum.any?(keys, &(not is_nil(progress_event_field(event, &1))))
    end)
  end

  defp progress_event_field(nil, _key), do: nil

  defp progress_event_field(event, key) do
    data = field(event, :data) || %{}
    nested = field(data, :data) || %{}

    field(nested, key) || field(data, key) || field(event, key)
  end

  defp objective_session_field(nil, _key), do: nil

  defp objective_session_field(event, key) do
    event
    |> progress_event_field(:objective_session)
    |> field(key)
  end

  defp objective_decision_field(nil, _key), do: nil

  defp objective_decision_field(event, key) do
    session_decision =
      event
      |> progress_event_field(:objective_session)
      |> field(:decision)

    top_level_decision = progress_event_field(event, :objective_decision)

    field(session_decision, key) || field(top_level_decision, key)
  end

  defp objective_error_field(nil, _key), do: nil

  defp objective_error_field(event, key) do
    summary_error =
      event
      |> progress_event_field(:objective_session)
      |> field(:latest_error)

    state_error =
      event
      |> progress_event_field(:objective_session_state)
      |> field(:latest_error)

    direct_error = progress_event_field(event, :latest_error)

    field(summary_error, key) ||
      field(state_error, key) ||
      field(direct_error, key) ||
      objective_session_field(event, :"latest_error_#{key}")
  end

  defp progress_task_count(nil, _key), do: nil

  defp progress_task_count(event, key) do
    case progress_event_field(event, key) do
      tasks when is_list(tasks) -> length(tasks)
      _other -> nil
    end
  end

  defp tool_call_view(%ToolCall{} = call) do
    %{
      id: call.id,
      session_id: call.session_id,
      workflow_run_id: call.workflow_run_id,
      tool_name: call.tool_name,
      tool_id: call.tool_id,
      status: call.status,
      args: call.args_json || %{},
      result: call.result_json || %{},
      error: call.error_json || %{},
      requested_at: call.requested_at,
      started_at: call.started_at,
      completed_at: call.completed_at
    }
  end

  defp run_view(%WorkflowRun{} = run) do
    %{
      id: run.id,
      workflow_key: run.workflow_key,
      workflow_name: run.workflow_name,
      status: run.status,
      trigger: run.trigger,
      metadata: run.metadata_json || %{},
      started_at: run.started_at || run.inserted_at,
      completed_at: run.completed_at,
      failed_at: run.failed_at
    }
  end

  defp review_request_view(%ReviewRequest{} = request) do
    %{
      id: request.id,
      session_id: request.session_id,
      workflow_run_id: request.workflow_run_id,
      tool_call_id: request.tool_call_id,
      kind: request.kind,
      checkpoint: request.checkpoint,
      resume_key: request.resume_key,
      status: request.status,
      details: request.details_json || %{},
      decision: request.decision_json || %{},
      inserted_at: request.inserted_at
    }
  end

  defp artifact_view(%RunArtifact{} = artifact) do
    metadata = artifact.metadata_json || %{}
    payload = metadata["payload"] || metadata[:payload] || %{}

    %{
      id: artifact.id,
      run_id: artifact.run_id,
      session_id: artifact.session_id,
      path: artifact.path,
      kind: artifact.artifact_kind,
      action: artifact.action,
      sha256: artifact.sha256,
      byte_size: artifact.byte_size,
      title:
        metadata["title"] || metadata[:title] || payload["title"] || payload[:title] ||
          artifact.path || artifact.id,
      preview:
        metadata["preview"] || metadata[:preview] || payload["preview"] || payload[:preview],
      metadata: metadata,
      inserted_at: artifact.inserted_at
    }
  end

  defp scorecard_view(%Scorecard{} = scorecard) do
    data = scorecard.scorecard_json || %{}

    %{
      id: scorecard.id,
      run_id: scorecard.run_id,
      component_id: scorecard.component_id,
      objective_status: scorecard.objective_status,
      summary: data["summary"] || data[:summary],
      acceptance_results: data["acceptance_results"] || data[:acceptance_results] || [],
      residual_risks: data["residual_risks"] || data[:residual_risks] || [],
      changed_files: data["changed_files"] || data[:changed_files] || [],
      data: data,
      created_at: scorecard.created_at
    }
  end

  defp objective_contract_view(events, messages, scorecards) do
    latest_from_events =
      events
      |> Enum.reverse()
      |> Enum.find_value(fn event ->
        data = event.data_json || %{}

        field(data, :objective_contract) ||
          data |> field(:blocked_evidence) |> field(:objective_contract)
      end)

    latest_from_messages =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn message ->
        data = message.content_json || %{}

        field(data, :objective_contract) ||
          data |> field(:blocked_evidence) |> field(:objective_contract)
      end)

    latest_from_scorecards =
      scorecards
      |> Enum.reverse()
      |> Enum.find_value(fn scorecard ->
        scorecard
        |> field(:data)
        |> field(:metadata)
        |> field(:objective_contract)
      end)

    latest_from_events || latest_from_messages || latest_from_scorecards
  end

  defp blocked_evidence_view(%AgentSession{} = session, events, messages, scorecards) do
    explicit =
      events
      |> Enum.reverse()
      |> Enum.find_value(fn event -> event.data_json |> field(:blocked_evidence) end) ||
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn message -> message.content_json |> field(:blocked_evidence) end)

    explicit || derived_blocked_evidence(session, events, scorecards)
  end

  defp derived_blocked_evidence(%AgentSession{status: status}, _events, _scorecards)
       when status not in ["blocked", "failed"],
       do: nil

  defp derived_blocked_evidence(%AgentSession{} = session, events, scorecards) do
    latest_scorecard = List.last(scorecards)
    latest_event = List.last(events)

    %{
      status: session.status,
      objective_status: field(latest_scorecard || %{}, :objective_status),
      residual_risks: field(latest_scorecard || %{}, :residual_risks) || [],
      unsatisfied_acceptance:
        latest_scorecard
        |> field(:acceptance_results)
        |> List.wrap()
        |> Enum.filter(&(field(&1, :status) in ["fail", :fail, "blocked", :blocked])),
      latest_event: event_view(latest_event),
      next_actions: [
        "Inspect the latest blocked event and unsatisfied acceptance checks.",
        "Continue with a targeted repair or rerun with a larger budget when the evidence is budget-related."
      ]
    }
    |> compact_map()
  end

  defp conversation_history(%{session_id: session_id, agent_route: agent_route}) do
    store = store!()

    store
    |> Queries.messages_for_session(session_id)
    |> visible_chat_messages()
    |> filter_routed_conversation_history(agent_route)
    |> Enum.map(fn message ->
      %{
        role: message.role,
        message_kind: message.message_kind,
        content: message.content || ""
      }
    end)
  rescue
    _exception -> []
  end

  defp filter_routed_conversation_history(messages, %{
         route_reason: :non_workspace_rlm_objective
       }) do
    Enum.reject(messages, fn message ->
      message.role == "assistant" and
        String.starts_with?(message.presentation_group_id || "", "rlm:web")
    end)
  end

  defp filter_routed_conversation_history(messages, _agent_route), do: messages

  defp inferred_output_path(objective) when is_binary(objective) do
    objective
    |> output_path_candidates()
    |> List.first()
  end

  defp inferred_output_path(_objective), do: nil

  defp output_path_candidates(objective) do
    Regex.scan(
      ~r/\b(?:write|save|create|persist|output|report)\b.{0,120}?\b(?:to|at|as|in)\s+(`[^`]+`|"[^"]+"|'[^']+'|[A-Za-z0-9_.\/-]+\.(?:md|txt|json|jsonl|csv|exs?|livemd))/i,
      objective,
      capture: :all_but_first
    )
    |> Enum.map(fn [path] -> normalize_referenced_path(path) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_referenced_path(path) do
    path
    |> String.trim(~s(`'" ))
    |> String.replace(~r/[,.!?;:)\]}]+$/, "")
  end

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {key, right_value}, acc ->
      key = equivalent_existing_key(acc, key)
      Map.update(acc, key, right_value, &deep_merge(&1, right_value))
    end)
  end

  defp deep_merge(_left, right), do: right

  defp equivalent_existing_key(map, key) when is_map(map) and is_binary(key) do
    Enum.find(Map.keys(map), key, fn
      existing when is_atom(existing) -> Atom.to_string(existing) == key
      existing -> existing == key
    end)
  end

  defp equivalent_existing_key(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)
    Enum.find(Map.keys(map), key, &(&1 == string_key or &1 == key))
  end

  defp equivalent_existing_key(_map, key), do: key

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp hash_source(source) do
    :crypto.hash(:sha256, source)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank_value?(value) end)
    |> Map.new()
  end

  defp blank_value?(nil), do: true
  defp blank_value?(""), do: true
  defp blank_value?([]), do: true
  defp blank_value?(map) when is_map(map), do: map_size(map) == 0
  defp blank_value?(_value), do: false

  defp require_objective(""), do: {:error, :empty_objective}
  defp require_objective(_objective), do: :ok

  defp choice(nil, _choices, default), do: {:ok, default}

  defp choice(value, choices, default) when is_atom(value) do
    if value in Map.values(choices), do: {:ok, value}, else: {:ok, default}
  end

  defp choice(value, choices, default) do
    normalized =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    {:ok, Map.get(choices, normalized, default)}
  end

  defp normalize_cwd(cwd) when is_binary(cwd) do
    path = Path.expand(cwd)

    if File.dir?(path) do
      {:ok, path}
    else
      {:error, {:invalid_cwd, cwd}}
    end
  end

  defp normalize_cwd(cwd), do: {:error, {:invalid_cwd, cwd}}

  defp normalize_max_runtime(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_max_runtime(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {runtime_ms, ""} when runtime_ms > 0 -> {:ok, runtime_ms}
      _other -> {:error, {:invalid_max_runtime_ms, value}}
    end
  end

  defp normalize_max_runtime(value), do: {:error, {:invalid_max_runtime_ms, value}}

  defp normalize_max_objective_iterations(value) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_max_objective_iterations(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {iterations, ""} when iterations > 0 -> {:ok, iterations}
      _other -> {:error, {:invalid_max_objective_iterations, value}}
    end
  end

  defp normalize_max_objective_iterations(value),
    do: {:error, {:invalid_max_objective_iterations, value}}

  defp normalize_model_selection(params, cfg) do
    direct_model = blank_to_nil(value(params, "model"))
    provider = blank_to_nil(value(params, "model_provider"))
    model_id = blank_to_nil(value(params, "model_id"))
    configured_default = blank_to_nil(Keyword.get(cfg, :default_model))

    cond do
      is_binary(provider) and is_binary(model_id) ->
        "#{provider}:#{model_id}"

      is_binary(direct_model) ->
        direct_model

      is_binary(configured_default) ->
        configured_default

      true ->
        ModelCatalog.default_model_spec()
    end
  end

  defp normalize_profile(nil), do: {:ok, "local-workbench"}

  defp normalize_profile(profile) when is_atom(profile),
    do: {:ok, profile |> Atom.to_string() |> String.replace("_", "-")}

  defp normalize_profile(profile) when is_binary(profile) do
    profile =
      profile
      |> String.trim()
      |> String.replace("_", "-")

    if profile == "", do: {:ok, "local-workbench"}, else: {:ok, profile}
  end

  defp normalize_profile(profile), do: {:ok, to_string(profile)}

  defp normalize_list(nil), do: {:ok, []}
  defp normalize_list(""), do: {:ok, []}

  defp normalize_list(value) when is_binary(value) do
    {:ok,
     value
     |> String.split([",", "\n"], trim: true)
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))
     |> Enum.uniq()}
  end

  defp normalize_list(values) when is_list(values) do
    {:ok,
     values
     |> Enum.flat_map(fn
       value when is_binary(value) -> String.split(value, [",", "\n"], trim: true)
       value -> [to_string(value)]
     end)
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))
     |> Enum.uniq()}
  end

  defp normalize_list(value), do: normalize_list(to_string(value))

  defp normalize_tool_config(nil), do: {:ok, %{}}
  defp normalize_tool_config(""), do: {:ok, %{}}

  defp normalize_tool_config(config) when is_map(config), do: {:ok, config}

  defp normalize_tool_config(config) when is_binary(config) do
    config
    |> String.split([",", "\n"], trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
      case String.split(entry, "=", parts: 2) do
        [key, value] ->
          path = key |> String.trim() |> String.split(".", trim: true)

          if path == [] do
            {:halt, {:error, {:invalid_tool_config, entry}}}
          else
            {:cont, {:ok, put_nested_config(acc, path, parse_config_value(String.trim(value)))}}
          end

        _other ->
          {:halt, {:error, {:invalid_tool_config, entry}}}
      end
    end)
  end

  defp normalize_sandbox_tool_config(config, params) when is_map(config) and is_map(params) do
    sandbox_values = [
      value(params, "sandbox_profile"),
      value(params, "sandbox_backend"),
      value(params, "sandbox_runtime"),
      value(params, "sandbox_network"),
      value(params, "sandbox_stateful"),
      value(params, "sandbox_pool_warm"),
      value(params, "sandbox_pool_max")
    ]

    if Enum.all?(sandbox_values, &blank?/1) do
      {:ok, config}
    else
      with {:ok, sandbox} <- normalize_sandbox_profile(value(params, "sandbox_profile")),
           {:ok, backend} <- normalize_sandbox_backend(value(params, "sandbox_backend")),
           {:ok, runtime} <- normalize_sandbox_runtime(value(params, "sandbox_runtime")),
           {:ok, network} <- normalize_sandbox_network(value(params, "sandbox_network")),
           {:ok, stateful?} <- normalize_sandbox_stateful(value(params, "sandbox_stateful")),
           {:ok, pool} <- normalize_sandbox_pool(params) do
        {:ok,
         config
         |> maybe_put_sandbox_config(["code_execution", "enabled"], true)
         |> maybe_put_sandbox_config(["code_execution", "sandbox"], sandbox)
         |> maybe_put_sandbox_config(["code_execution", "backend"], backend)
         |> maybe_put_sandbox_config(["code_execution", "default_backend"], backend)
         |> maybe_put_sandbox_config(["code_execution", "allowed_runtimes"], [runtime])
         |> maybe_put_sandbox_config(["code_execution", "network"], network)
         |> maybe_put_sandbox_config(["code_execution", "stateful?"], stateful?)
         |> maybe_put_sandbox_config(["code_execution", "pool"], pool)
         |> maybe_put_sandbox_config(["code_execution", "workspace", "mode"], "copy_in")
         |> maybe_put_sandbox_config(["code_execution", "workspace", "persist?"], stateful?)}
      end
    end
  end

  defp normalize_sandbox_tool_config(config, _params), do: {:ok, config}

  defp maybe_put_sandbox_config(config, _path, nil), do: config
  defp maybe_put_sandbox_config(config, path, value), do: put_nested_config(config, path, value)

  defp normalize_sandbox_profile(value) do
    value =
      value
      |> blank_to_nil()
      |> case do
        nil ->
          "local_code"

        value ->
          value
          |> to_string()
          |> String.trim()
          |> String.downcase()
          |> String.replace("-", "_")
      end

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, value) do
      {:ok, value}
    else
      {:error, {:invalid_sandbox_profile, value}}
    end
  end

  defp normalize_sandbox_backend(value) do
    value =
      value
      |> blank_to_nil()
      |> case do
        nil ->
          "just_bash"

        value ->
          value |> to_string() |> String.trim() |> String.downcase() |> String.replace("-", "_")
      end

    if value in ~w(just_bash docker podman gvisor vmsan firecracker sprites remote) do
      {:ok, value}
    else
      {:error, {:invalid_sandbox_backend, value}}
    end
  end

  defp normalize_sandbox_runtime(value) do
    value =
      value
      |> blank_to_nil()
      |> case do
        nil -> "bash"
        value -> value |> to_string() |> String.trim() |> String.downcase()
      end

    if value in ~w(bash sh python node elixir lua) do
      {:ok, value}
    else
      {:error, {:invalid_sandbox_runtime, value}}
    end
  end

  defp normalize_sandbox_network(value) do
    value =
      value
      |> blank_to_nil()
      |> case do
        nil -> "disabled"
        value -> value |> to_string() |> String.trim() |> String.downcase()
      end

    if value in ~w(disabled restricted host) do
      {:ok, value}
    else
      {:error, {:invalid_sandbox_network, value}}
    end
  end

  defp normalize_sandbox_stateful(value) when value in [true, false], do: {:ok, value}
  defp normalize_sandbox_stateful(value) when value in [nil, ""], do: {:ok, false}
  defp normalize_sandbox_stateful(value) when value in ["true", "1", "yes", "on"], do: {:ok, true}

  defp normalize_sandbox_stateful(value) when value in ["false", "0", "no", "off"],
    do: {:ok, false}

  defp normalize_sandbox_stateful(value), do: {:error, {:invalid_sandbox_stateful, value}}

  defp normalize_sandbox_pool(params) do
    with {:ok, warm} <- normalize_non_negative_integer(value(params, "sandbox_pool_warm"), 0),
         {:ok, max} <- normalize_positive_integer(value(params, "sandbox_pool_max"), 1) do
      if warm <= max do
        {:ok, %{"warm" => warm, "max" => max}}
      else
        {:error, {:invalid_sandbox_pool, %{warm: warm, max: max}}}
      end
    end
  end

  defp normalize_non_negative_integer(value, default) when value in [nil, ""],
    do: {:ok, default}

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp normalize_non_negative_integer(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, {:invalid_non_negative_integer, value}}
    end
  end

  defp normalize_non_negative_integer(value, _default),
    do: {:error, {:invalid_non_negative_integer, value}}

  defp normalize_positive_integer(value, default) when value in [nil, ""], do: {:ok, default}

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_positive_integer(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_positive_integer, value}}
    end
  end

  defp normalize_positive_integer(value, _default),
    do: {:error, {:invalid_positive_integer, value}}

  defp blank?(value), do: is_nil(blank_to_nil(value))

  defp sandbox_launch_summary(tool_config, capability_profile) do
    profile_config =
      capability_profile
      |> field(:config)
      |> field(:code_execution)

    configured = field(tool_config, "code_execution") || %{}
    code_execution = deep_merge(profile_config || %{}, configured)

    %{
      sandbox: field(code_execution, :sandbox) || :local_code,
      backend:
        field(code_execution, :default_backend) || field(code_execution, :backend) || :just_bash,
      runtimes:
        field(code_execution, :allowed_runtimes) || field(code_execution, :runtimes) || [:bash],
      network: field(code_execution, :network) || :disabled,
      stateful?: field(code_execution, :stateful?) || false,
      pool: field(code_execution, :pool) || %{},
      workspace: field(code_execution, :workspace) || %{},
      review: field(code_execution, :review) || :unsafe_actions
    }
  end

  defp parse_config_value("true"), do: true
  defp parse_config_value("false"), do: false

  defp parse_config_value(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp put_nested_config(config, [key], value), do: Map.put(config, key, value)

  defp put_nested_config(config, [key | rest], value) do
    Map.update(config, key, put_nested_config(%{}, rest, value), fn nested ->
      put_nested_config(Map.new(nested || %{}), rest, value)
    end)
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, Map.get(@param_atoms, key))
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp first_present(nil, fallback), do: fallback
  defp first_present("", fallback), do: fallback
  defp first_present(value, _fallback), do: value

  defp short_id(id) when is_binary(id) do
    id
    |> String.split(":")
    |> List.last()
    |> String.slice(0, 8)
  end

  defp short_id(_id), do: nil

  defp mode_arg(:read_only), do: "read-only"
  defp mode_arg(mode), do: Atom.to_string(mode)

  defp write_policy_arg(:docs_only), do: "docs-only"
  defp write_policy_arg(:workspace_review), do: "workspace-review"
  defp write_policy_arg(:none), do: "none"
  defp write_policy_arg(policy), do: to_string(policy)

  defp default_write_policy(:patch), do: :workspace_review
  defp default_write_policy(_mode), do: :docs_only

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, _flag, ""), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, to_string(value)]

  defp append_objective_loop_args(args, %{agent: :rlm, max_objective_iterations: iterations}) do
    args ++ ["--objective-loop", "--max-objective-iterations", Integer.to_string(iterations)]
  end

  defp append_objective_loop_args(args, _launch), do: args

  defp maybe_append_list(args, _flag, []), do: args
  defp maybe_append_list(args, _flag, nil), do: args

  defp maybe_append_list(args, flag, values),
    do: args ++ [flag, Enum.join(List.wrap(values), ",")]

  defp append_repeated(args, _flag, []), do: args
  defp append_repeated(args, _flag, nil), do: args

  defp append_repeated(args, flag, values) do
    Enum.reduce(List.wrap(values), args, fn value, acc -> acc ++ [flag, to_string(value)] end)
  end

  defp append_tool_config(args, config) when config in [nil, %{}], do: args

  defp append_tool_config(args, config) when is_map(config) do
    config
    |> flatten_tool_config()
    |> Enum.reduce(args, fn {key, value}, acc ->
      acc ++ ["--tool-config", "#{key}=#{tool_config_cli_value(value)}"]
    end)
  end

  defp tool_config_cli_value(values) when is_list(values),
    do: values |> Enum.map(&to_string/1) |> Enum.join(",")

  defp tool_config_cli_value(value), do: to_string(value)

  defp flatten_tool_config(config, prefix \\ nil) do
    Enum.flat_map(config, fn {key, value} ->
      key = if prefix, do: "#{prefix}.#{key}", else: to_string(key)

      if is_map(value) do
        flatten_tool_config(value, key)
      else
        [{key, value}]
      end
    end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp session_topic(session_id), do: "#{@topic}:session:#{session_id}"
end
