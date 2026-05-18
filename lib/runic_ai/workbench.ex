defmodule RunicAI.Workbench do
  @moduledoc """
  Local workbench API shared by Phoenix LiveViews and future server packaging.

  The durable SQLite store remains the source of truth. This module provides
  bounded query projections and small PubSub invalidations for web surfaces.
  """

  alias RunicAI.Ids
  alias RunicAI.Coding.Review
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
  alias RunicAI.Workbench.StoreServer

  @topic "runic_ai:workbench"
  @task_supervisor RunicAI.Workbench.TaskSupervisor

  @agent_choices %{"assistant" => :assistant, "standard" => :standard, "rlm" => :rlm}
  @approval_choices %{"safe" => :safe, "never" => :never, "ask" => :ask}
  @mode_choices %{"verify" => :verify, "patch" => :patch, "read_only" => :read_only}
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
    "objective" => :objective,
    "rewrite" => :rewrite,
    "run_id" => :run_id,
    "session_id" => :session_id
  }

  @spec store() :: {:ok, Store.t()} | {:error, term()}
  def store, do: StoreServer.store()

  @spec store!() :: Store.t()
  def store!, do: StoreServer.store!()

  @spec health() :: map()
  def health, do: StoreServer.health()

  @spec config() :: keyword()
  def config, do: Application.get_env(:runic_ai, :workbench, [])

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

      %{
        session: session_view(session),
        messages: Enum.map(messages, &message_view/1),
        events: Enum.map(events, &event_view/1),
        tool_calls: Enum.map(tools, &tool_call_view/1),
        runs: Enum.map(runs, &run_view/1),
        review_requests: Enum.map(reviews, &review_request_view/1),
        artifacts: Enum.map(artifacts, &artifact_view/1),
        scorecards: Enum.map(scorecards, &scorecard_view/1),
        metrics: %{
          messages: length(messages),
          events: length(events),
          tool_calls: length(tools),
          runs: length(runs),
          review_requests: length(reviews),
          artifacts: length(artifacts),
          scorecards: length(scorecards)
        }
      }
    end
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
         {:ok, decision} <- normalize_review_decision(params) do
      record_terminal_event(review_decision_event(session_id, review, decision))
    end
  end

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
         {:ok, cwd} <- normalize_cwd(value(params, "cwd") || File.cwd!()),
         {:ok, max_runtime_ms} <-
           normalize_max_runtime(
             value(params, "max_runtime_ms") || Keyword.get(cfg, :max_runtime_ms, 300_000)
           ) do
      {agent, agent_route} = route_agent(agent, objective)
      session_id = value(params, "session_id") || Ids.unique("web-session")
      run_id = value(params, "run_id") || Ids.unique("#{agent}:web")

      {:ok,
       %{
         session_id: session_id,
         run_id: run_id,
         objective: objective,
         agent: agent,
         agent_route: agent_route,
         cwd: cwd,
         model: blank_to_nil(value(params, "model") || Keyword.get(cfg, :default_model)),
         client: blank_to_nil(value(params, "client") || Keyword.get(cfg, :default_client)),
         approve: approve,
         mode: mode,
         run_fun: Keyword.get(cfg, :run_fun),
         max_runtime_ms: max_runtime_ms
       }}
    end
  end

  defp route_agent(:rlm, objective) do
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

  defp route_agent(agent, _objective), do: {agent, nil}

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

  defp browser_review_decider(%{approve: :ask} = launch) do
    fn %RuntimeReviewRequest{} = request, context ->
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

  defp browser_review_decider(_launch), do: nil

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
    case field(decision, :decision) || field(decision, :status) do
      action when action in ["approve", :approve, "approved", :approved] ->
        {:ok, Review.allow(request, reason: "approved in browser")}

      action
      when action in ["deny", :deny, "denied", :denied, "reject", :reject, "rejected", :rejected] ->
        {:ok, Review.deny(request, reason: "denied in browser")}

      action when action in ["stop", :stop, "cancelled", :cancelled, "cancel", :cancel] ->
        {:ok, Review.final_stop(request, reason: "stopped in browser")}

      action when action in ["rewrite", :rewrite, "edited", :edited] ->
        {:ok,
         Review.rewrite(request, field(decision, :edited_value) || "",
           reason: "rewritten in browser"
         )}

      _other ->
        :ignore
    end
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

    case action do
      "approve" ->
        {:ok, %{action: "approve", status: :ok, decision_status: "approved"}}

      "deny" ->
        {:ok, %{action: "deny", status: :blocked, decision_status: "denied"}}

      "stop" ->
        {:ok, %{action: "stop", status: :blocked, decision_status: "cancelled"}}

      "rewrite" when rewrite != "" ->
        {:ok,
         %{
           action: "rewrite",
           status: :ok,
           decision_status: "edited",
           edited_value: rewrite
         }}

      "rewrite" ->
        {:error, :empty_rewrite}

      _other ->
        {:error, :invalid_review_decision}
    end
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
        decision: %{
          decision: decision.action,
          status: decision.decision_status,
          edited_value: Map.get(decision, :edited_value),
          decided_at: decided_at
        }
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
      "--approve",
      Atom.to_string(launch.approve),
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
          max_runtime_ms: launch.max_runtime_ms,
          trigger: "browser"
        }
        |> put_agent_route(launch),
      at: DateTime.utc_now()
    }
  end

  defp put_agent_route(data, %{agent_route: nil}), do: data
  defp put_agent_route(data, %{agent_route: route}) when is_map(route), do: Map.merge(data, route)
  defp put_agent_route(data, _launch), do: data

  defp session_view(%AgentSession{} = session) do
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
      metadata: session.metadata_json || %{},
      short_id: short_id(session.id)
    }
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

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, _flag, ""), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp session_topic(session_id), do: "#{@topic}:session:#{session_id}"
end
