defmodule RunicAI.Terminal.AgentRunner do
  @moduledoc """
  Orchestrates terminal presentation around backend agent runners.

  Backend modules emit normalized events. This module wires those events to
  plain text output, JSONL export, and review prompts.
  """

  alias RunicAI.Coding.Review
  alias RunicAI.Coding.RLM.ObjectiveSession
  alias RunicAI.Error
  alias RunicAI.Ids
  alias RunicAI.Persistence.SQLite
  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.AssistantRunner
  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.InteractiveContext
  alias RunicAI.Terminal.JsonlSink
  alias RunicAI.Terminal.RLMRunner
  alias RunicAI.Terminal.Renderer
  alias RunicAI.Terminal.ReviewPrompt
  alias RunicAI.Terminal.StandardRunner

  @default_objective_auto_resume_limit 5

  @spec run(CliOptions.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(options, opts \\ [])

  def run(%CliOptions{help?: true}, opts) do
    output_fun = Keyword.get(opts, :output_fun, &IO.puts/1)
    output_fun.(CliOptions.usage())
    {:ok, %{status: :help}}
  end

  def run(%CliOptions{} = options, opts) do
    options = ensure_session_id(options)
    output_fun = Keyword.get(opts, :output_fun, &IO.puts/1)
    input_fun = Keyword.get(opts, :input_fun, &IO.gets/1)

    with {:ok, jsonl} <- JsonlSink.open(options.jsonl_path),
         {:ok, persistence} <- open_persistence(options, opts) do
      try do
        renderer = Renderer.new(options, opts)
        output_fun.(Renderer.render_header(renderer, header_opts(options, renderer)))

        store = persistence_store(persistence)
        event_sink = event_sink(jsonl, store, output_fun, renderer)
        emit_model_preflight(options, Keyword.get(opts, :run_id), event_sink)

        opts =
          opts |> Keyword.put(:persistence_store, store) |> Keyword.put(:session_store, store)

        if options.interactive? do
          run_interactive(options, event_sink, input_fun, output_fun, renderer, opts)
        else
          run_once(options, event_sink, input_fun, output_fun, renderer, opts)
        end
      after
        close_persistence(persistence)
        JsonlSink.close(jsonl)
      end
    end
  end

  defp run_once(%CliOptions{} = options, event_sink, input_fun, output_fun, renderer, opts) do
    runner_opts = runner_opts(options, event_sink, input_fun, output_fun, renderer, opts)

    result =
      options
      |> run_backend_agent(runner_opts)
      |> maybe_resume_objective_loop(options, runner_opts, 0)

    emit_final_event(result, options, event_sink)
    render_final(result, output_fun, renderer)
    result
  end

  defp run_backend_agent(%CliOptions{} = options, runner_opts) do
    case options.agent do
      :assistant -> AssistantRunner.run(options.objective, runner_opts)
      :standard -> StandardRunner.run(options.objective, runner_opts)
      :rlm -> RLMRunner.run(options.objective, runner_opts)
    end
  end

  defp maybe_resume_objective_loop(
         {:ok, %{agent: :rlm} = result},
         %CliOptions{} = options,
         runner_opts,
         attempt
       ) do
    limit = objective_auto_resume_limit(runner_opts)

    case objective_operator_request(result) do
      {:ok, resume_kind, request, session} when attempt >= limit ->
        capped =
          mark_objective_auto_resume_limit(result, resume_kind, request, session, attempt, limit)

        emit_objective_auto_resume_limit(capped, resume_kind, request, session, runner_opts)
        {:ok, capped}

      {:ok, resume_kind, request, session} ->
        with {:ok, decision} <- decide_objective_operator_request(request, result, runner_opts),
             {:ok, resumed} <- resume_objective_loop(resume_kind, session, decision, runner_opts) do
          maybe_resume_objective_loop({:ok, resumed}, options, runner_opts, attempt + 1)
        end

      :none ->
        {:ok, result}
    end
  end

  defp maybe_resume_objective_loop(result, _options, _runner_opts, _attempt), do: result

  defp objective_auto_resume_limit(runner_opts) do
    case Keyword.get(
           runner_opts,
           :max_objective_auto_resumes,
           @default_objective_auto_resume_limit
         ) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _other -> @default_objective_auto_resume_limit
    end
  end

  defp mark_objective_auto_resume_limit(result, resume_kind, request, session, attempts, limit) do
    Map.merge(result, %{
      objective_auto_resume_exhausted?: true,
      objective_resume_attempts: attempts,
      objective_resume_limit: limit,
      objective_resume_kind: resume_kind,
      objective_resume_request: %{
        kind: request.kind,
        checkpoint: request.checkpoint,
        resume_key: request.resume_key
      },
      objective_session: session
    })
  end

  defp emit_objective_auto_resume_limit(result, resume_kind, request, session, runner_opts) do
    case Keyword.get(runner_opts, :event_sink) do
      sink when is_function(sink, 1) ->
        sink.(
          Event.new!(:status,
            session_id: Map.get(result, :session_id) || session.id,
            run_id: Map.get(result, :run_id) || session.id,
            agent: :rlm,
            phase: :objective_loop_resume,
            status: :blocked,
            title: "Objective auto-resume limit reached",
            detail:
              "objective still needs #{resume_kind} approval after #{Map.get(result, :objective_resume_attempts)} automatic resumes",
            data:
              %{
                run_id: Map.get(result, :run_id) || session.id,
                objective_session_id: session.id,
                objective: session.objective,
                objective_session: ObjectiveSession.summary(session),
                objective_session_state: ObjectiveSession.to_map(session),
                objective_decision: Map.get(result, :objective_decision),
                objective_iteration_count: length(session.iterations),
                objective_status: session.status,
                resume_kind: resume_kind,
                resume_key: request.resume_key,
                max_objective_auto_resumes: Map.get(result, :objective_resume_limit),
                open_tasks: session.open_tasks,
                completed_tasks: session.completed_tasks,
                review_requests: session.review_requests,
                budget_requests: session.budget_requests
              }
              |> Enum.reject(fn {_key, value} -> is_nil(value) end)
              |> Map.new()
          )
        )

      _other ->
        :ok
    end
  end

  defp objective_operator_request(%{
         objective_decision: %{action: :request_review_approval, request: raw_request},
         objective_session: %RunicAI.Coding.RLM.ObjectiveSession{} = session
       }) do
    build_objective_review_request(raw_request, :review, session)
  end

  defp objective_operator_request(%{
         objective_decision: %{action: :request_budget_approval, request: raw_request},
         objective_session: %RunicAI.Coding.RLM.ObjectiveSession{} = session
       }) do
    build_objective_review_request(raw_request, :budget, session)
  end

  defp objective_operator_request(_result), do: :none

  defp build_objective_review_request(raw_request, resume_kind, session)
       when is_map(raw_request) do
    kind = objective_request_kind(raw_request, resume_kind)
    resume_key = objective_request_resume_key(raw_request)

    if is_binary(resume_key) and resume_key != "" do
      request =
        ReviewRequest.new!(kind,
          subject:
            field(raw_request, :subject) || objective_request_subject(raw_request, resume_kind),
          checkpoint:
            field(raw_request, :checkpoint) || objective_request_checkpoint(resume_kind),
          resume_key: resume_key,
          options: objective_request_options(raw_request, resume_kind),
          details: objective_request_details(raw_request, session),
          metadata:
            objective_request_metadata(raw_request)
            |> Map.put(:objective_loop?, true)
            |> Map.put(:resume_kind, resume_kind)
        )

      {:ok, resume_kind, request, session}
    else
      :none
    end
  end

  defp build_objective_review_request(_raw_request, _resume_kind, _session), do: :none

  defp decide_objective_operator_request(%ReviewRequest{} = request, result, runner_opts) do
    runner_opts
    |> Keyword.fetch!(:review_decider)
    |> then(fn decider ->
      decider.(request, %{
        session_id: Map.get(result, :session_id),
        run_id: Map.get(result, :run_id),
        objective_session: Map.get(result, :objective_session),
        objective_decision: Map.get(result, :objective_decision)
      })
    end)
  end

  defp resume_objective_loop(:review, session, decision, runner_opts) do
    RLMRunner.resume_after_review(session, decision, runner_opts)
  end

  defp resume_objective_loop(:budget, session, decision, runner_opts) do
    RLMRunner.resume_after_budget(session, decision, runner_opts)
  end

  defp objective_request_kind(raw_request, :review) do
    case field(raw_request, :kind) do
      kind when is_atom(kind) -> kind
      "objective_plan_approval" -> :objective_plan_approval
      "objective_review" -> :objective_review
      _other -> :objective_review
    end
  end

  defp objective_request_kind(raw_request, :budget) do
    case field(raw_request, :kind) do
      kind when is_atom(kind) -> kind
      "objective_budget_approval" -> :objective_budget_approval
      _other -> :objective_budget_approval
    end
  end

  defp objective_request_resume_key(raw_request) do
    field(raw_request, :resume_key) || field(raw_request, :id)
  end

  defp objective_request_subject(raw_request, :budget) do
    field(raw_request, :reason) || "Objective needs additional budget"
  end

  defp objective_request_subject(raw_request, _resume_kind) do
    field(raw_request, :reason) || field(raw_request, :path) ||
      "Objective needs operator approval"
  end

  defp objective_request_checkpoint(:budget), do: :budget_approval
  defp objective_request_checkpoint(_resume_kind), do: :objective_review

  defp objective_request_options(raw_request, :budget) do
    case field(raw_request, :options) do
      options when is_list(options) and options != [] -> options
      _other -> [:approve, :reject, :cancel]
    end
  end

  defp objective_request_options(raw_request, _resume_kind) do
    case field(raw_request, :options) do
      options when is_list(options) and options != [] -> options
      _other -> [:approve, :reject, :edit, :cancel]
    end
  end

  defp objective_request_details(raw_request, session) do
    extra_details =
      %{
        reason: field(raw_request, :reason),
        suggested_next_action: field(raw_request, :suggested_next_action),
        current_iteration: field(raw_request, :current_iteration),
        max_iterations: field(raw_request, :max_iterations),
        scorecard_status: field(raw_request, :scorecard_status),
        repair_status: field(raw_request, :repair_status),
        objective_session_id: session.id,
        objective_status: session.status
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    raw_request
    |> field(:details)
    |> case do
      details when is_map(details) -> details
      _other -> %{}
    end
    |> Map.merge(extra_details)
  end

  defp objective_request_metadata(raw_request) do
    case field(raw_request, :metadata) do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  defp run_interactive(%CliOptions{} = options, event_sink, input_fun, output_fun, renderer, opts) do
    initial =
      case options.objective do
        nil ->
          :ok

        "" ->
          :ok

        objective ->
          run_interactive_objective(
            options,
            objective,
            event_sink,
            input_fun,
            output_fun,
            renderer,
            opts,
            nil
          )
      end

    case initial do
      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        interactive_loop(options, event_sink, input_fun, output_fun, renderer, opts, nil)
    end
  end

  defp interactive_loop(options, event_sink, input_fun, output_fun, renderer, opts, last_result) do
    case input_fun.("runic_ai> ") do
      nil ->
        {:ok, last_result || %{status: :completed}}

      input ->
        objective = String.trim(input)

        cond do
          objective in ["", "\n"] ->
            interactive_loop(
              options,
              event_sink,
              input_fun,
              output_fun,
              renderer,
              opts,
              last_result
            )

          objective in [":quit", "/quit", "quit"] ->
            {:ok, last_result || %{status: :completed}}

          true ->
            case run_interactive_objective(
                   options,
                   objective,
                   event_sink,
                   input_fun,
                   output_fun,
                   renderer,
                   opts,
                   last_result
                 ) do
              {:ok, result} ->
                interactive_loop(
                  options,
                  event_sink,
                  input_fun,
                  output_fun,
                  renderer,
                  opts,
                  result
                )

              {:error, %Error{} = error} ->
                {:error, error}
            end
        end
    end
  end

  defp run_interactive_objective(
         options,
         objective,
         event_sink,
         input_fun,
         output_fun,
         renderer,
         opts,
         last_result
       ) do
    options = %{options | objective: InteractiveContext.add_carryover(objective, last_result)}
    run_once(options, event_sink, input_fun, output_fun, renderer, opts)
  end

  defp runner_opts(%CliOptions{} = options, event_sink, input_fun, output_fun, renderer, opts) do
    [
      cwd: options.cwd,
      model: options.model,
      client: options.client,
      client_label: options.client_label,
      model_resolution: options.model_resolution,
      max_turns: options.max_turns,
      max_runtime_ms: options.max_runtime_ms,
      max_objective_iterations: options.max_objective_iterations,
      proposal_timeout_ms: options.proposal_timeout_ms,
      objective_loop?: options.objective_loop?,
      repair?: rlm_repair_enabled?(options),
      max_repair_iterations: rlm_max_repairs(options),
      seed_project_generation?: options.seed_project_generation?,
      session_id: options.session_id,
      run_id: Keyword.get(opts, :run_id),
      conversation_history: Keyword.get(opts, :conversation_history, []),
      mode: options.mode,
      profile: options.profile,
      toolsets: options.toolsets,
      disabled_tools: options.disabled_tools,
      allowed_tools: options.allowed_tools,
      tool_config: options.tool_config,
      approval: options.approve,
      input_paths: options.input_paths,
      output_path: options.output_path,
      max_generated_function_tier: max_generated_function_tier(options.allow_generated_functions),
      write_policy: options.write_policy,
      memory_store: Keyword.get(opts, :memory_store),
      memory_store_opts: Keyword.get(opts, :memory_store_opts),
      session_store: Keyword.get(opts, :session_store),
      tool_requirement: inferred_tool_requirement(options),
      proposal: Keyword.get(opts, :proposal),
      semantic_progress?: Keyword.get(opts, :semantic_progress?),
      objective_contract: Keyword.get(opts, :objective_contract),
      semantic_judge: Keyword.get(opts, :semantic_judge),
      semantic_judge_generation: Keyword.get(opts, :semantic_judge_generation),
      semantic_model: Keyword.get(opts, :semantic_model),
      semantic_client: Keyword.get(opts, :semantic_client),
      semantic_llm_opts: Keyword.get(opts, :semantic_llm_opts),
      semantic_evidence_policy: Keyword.get(opts, :semantic_evidence_policy),
      progress_policy: Keyword.get(opts, :progress_policy),
      max_objective_auto_resumes: Keyword.get(opts, :max_objective_auto_resumes),
      repair_opts: rlm_repair_opts(options, opts),
      event_sink: event_sink,
      review_decider:
        Keyword.get(opts, :review_decider) ||
          review_decider(options, input_fun, output_fun, renderer, event_sink),
      run_fun: Keyword.get(opts, :run_fun)
    ]
    |> maybe_put_runner_opt(:command, rlm_recipe(options))
    |> Keyword.merge(CliOptions.concurrency_opts(options))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_put_runner_opt(opts, _key, nil), do: opts
  defp maybe_put_runner_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_session_id(%CliOptions{session_id: session_id} = options)
       when is_binary(session_id) and session_id != "",
       do: options

  defp ensure_session_id(%CliOptions{} = options) do
    %{options | session_id: Ids.unique("#{options.agent}:cli")}
  end

  defp rlm_recipe(%CliOptions{agent: :rlm, tool_config: tool_config}) do
    tool_config
    |> nested_config(["rlm", "recipe"])
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp rlm_recipe(%CliOptions{}), do: nil

  defp rlm_repair_enabled?(%CliOptions{agent: :rlm, repair?: repair?}) when is_boolean(repair?),
    do: repair?

  defp rlm_repair_enabled?(%CliOptions{agent: :rlm, mode: :patch}), do: true
  defp rlm_repair_enabled?(%CliOptions{agent: :rlm}), do: false
  defp rlm_repair_enabled?(%CliOptions{}), do: nil

  defp rlm_max_repairs(%CliOptions{agent: :rlm, max_repairs: max_repairs})
       when is_integer(max_repairs),
       do: max_repairs

  defp rlm_max_repairs(%CliOptions{}), do: nil

  defp rlm_repair_opts(%CliOptions{agent: :rlm}, opts) do
    opts
    |> Keyword.get(:repair_opts, [])
    |> maybe_put_runner_opt(:executor, Keyword.get(opts, :repair_executor))
    |> case do
      [] -> nil
      repair_opts -> repair_opts
    end
  end

  defp rlm_repair_opts(%CliOptions{}, _opts), do: nil

  defp nested_config(config, [key]) when is_map(config) do
    Map.get(config, key) || Map.get(config, static_config_key(key))
  end

  defp nested_config(config, [key | rest]) when is_map(config) do
    config
    |> nested_config([key])
    |> nested_config(rest)
  end

  defp nested_config(_config, _path), do: nil

  defp static_config_key("rlm"), do: :rlm
  defp static_config_key("recipe"), do: :recipe
  defp static_config_key(key), do: key

  defp max_generated_function_tier(:tier0), do: :tier0
  defp max_generated_function_tier(:tier1), do: :tier1
  defp max_generated_function_tier(:tier2_review), do: :tier2

  defp inferred_tool_requirement(%CliOptions{agent: :standard, objective: objective}) do
    if local_command_objective?(objective), do: :required, else: nil
  end

  defp inferred_tool_requirement(%CliOptions{}), do: nil

  defp local_command_objective?(objective) when is_binary(objective) do
    objective = String.downcase(objective)

    (String.contains?(objective, "command") or
       String.contains?(objective, "terminal") or
       String.contains?(objective, "shell") or
       String.contains?(objective, "cli")) and
      Regex.match?(~r/(^|[^a-z0-9_])(run|execute|invoke|call)([^a-z0-9_]|$)/, objective)
  end

  defp local_command_objective?(_objective), do: false

  defp event_sink(jsonl, persistence, output_fun, renderer) do
    fn event ->
      _ = JsonlSink.write_event(jsonl, event)
      _ = write_persistence_event(persistence, event)

      event
      |> then(&Renderer.render_event(renderer, &1))
      |> output_fun.()

      :ok
    end
  end

  defp open_persistence(%CliOptions{} = options, opts) do
    case Keyword.fetch(opts, :persistence) do
      {:ok, persistence} ->
        {:ok, {:external, persistence}}

      :error ->
        open_cli_persistence(options)
    end
  end

  defp open_cli_persistence(%CliOptions{persistence: :none}), do: {:ok, {:external, nil}}

  defp open_cli_persistence(%CliOptions{persistence: :memory}) do
    case SQLite.open(database: ":memory:", migrate?: true) do
      {:ok, store} -> {:ok, {:owned, store}}
      {:error, _reason} = error -> error
    end
  end

  defp open_cli_persistence(%CliOptions{persistence: :sqlite, sqlite_path: path}) do
    case SQLite.open(database: path, migrate?: true) do
      {:ok, store} -> {:ok, {:owned, store}}
      {:error, _reason} = error -> error
    end
  end

  defp persistence_store({_ownership, store}), do: store

  defp close_persistence({:owned, %RunicAI.Persistence.SQLite.Store{} = store}),
    do: SQLite.close(store)

  defp close_persistence(_persistence), do: :ok

  defp write_persistence_event(%RunicAI.Persistence.SQLite.Store{} = store, event) do
    with {:ok, persisted} <- SQLite.record_terminal_event(store, event) do
      RunicAI.Workbench.broadcast_terminal_event(persisted)
      {:ok, persisted}
    end
  end

  defp write_persistence_event(_persistence, _event), do: :ok

  defp review_decider(%CliOptions{} = options, input_fun, output_fun, renderer, event_sink) do
    fn request, context ->
      case options.approve do
        :always ->
          {:ok, Review.allow(request, reason: "review approved by --approve always")}

        :never ->
          reason = "review denied by --approve never"
          emit_review_blocked(event_sink, request, context, reason)
          {:ok, Review.deny(request, reason: reason)}

        :safe ->
          if safe_review?(request) do
            {:ok, Review.allow(request, reason: "review approved by --approve safe")}
          else
            ask_review(request, context, input_fun, output_fun, renderer)
          end

        :ask ->
          ask_review(request, context, input_fun, output_fun, renderer)
      end
    end
  end

  defp ask_review(%ReviewRequest{} = request, _context, input_fun, output_fun, renderer) do
    output_fun.(Renderer.render_review_prompt(renderer, request))

    prompt_opts =
      if renderer.name == :owl do
        [renderer: :owl]
      else
        [renderer: :text, input_fun: input_fun]
      end

    ReviewPrompt.decide(request, prompt_opts)
  end

  defp emit_review_blocked(event_sink, request, context, reason) do
    event = ReviewPrompt.blocked_event(request, Map.take(context, [:session_id]), reason)

    event_sink.(event)
  end

  defp emit_final_event({:ok, result}, %CliOptions{} = options, event_sink) when is_map(result) do
    status = Map.get(result, :status, :ok)

    event =
      Event.new!(:summary,
        session_id: Map.get(result, :session_id) || options.session_id,
        agent: options.agent,
        phase: :final,
        status: terminal_status(status),
        title: "Agent finished",
        detail: "status: #{status}",
        data: %{
          run_id: Map.get(result, :run_id) || Map.get(result, :session_id) || options.session_id,
          result_status: status,
          objective_status: objective_status(result)
        }
      )

    event_sink.(event)
  end

  defp emit_final_event({:error, %Error{} = error}, %CliOptions{} = options, event_sink) do
    artifact_outcome = Event.artifact_outcome_from_error(error)

    event =
      Event.new!(:error,
        session_id: options.session_id,
        agent: options.agent,
        phase: :final,
        status: :error,
        title: "Agent failed",
        detail: error.message,
        data:
          %{
            run_id: options.session_id,
            error: Map.take(error, [:kind, :message, :details, :source, :retryable?, :metadata])
          }
          |> maybe_put(:artifact_outcome, artifact_outcome)
          |> maybe_put(:suggested_paths, suggested_paths(artifact_outcome))
      )

    event_sink.(event)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp suggested_paths(nil), do: nil
  defp suggested_paths(%{suggested_paths: paths}) when is_list(paths), do: paths
  defp suggested_paths(%{"suggested_paths" => paths}) when is_list(paths), do: paths
  defp suggested_paths(_outcome), do: nil

  defp terminal_status(status)
       when status in [:blocked, "blocked", :needs_budget_approval, "needs_budget_approval"],
       do: :blocked

  defp terminal_status(status)
       when status in [:review, "review", :needs_review_approval, "needs_review_approval"],
       do: :review

  defp terminal_status(status) when status in [:error, :failed, "error", "failed"], do: :error
  defp terminal_status(_status), do: :ok

  defp objective_status(result) do
    case Map.get(result, :objective_session) do
      %ObjectiveSession{status: status} -> status
      _other -> scorecard_objective_status(result)
    end
  end

  defp scorecard_objective_status(result) do
    case Map.get(result, :scorecard, Map.get(result, :objective_scorecard, %{})) do
      %{objective_status: status} -> status
      %{"objective_status" => status} -> status
      _other -> nil
    end
  end

  defp safe_review?(%ReviewRequest{} = request) do
    request.metadata[:safe?] in [true, "true"] or
      request.details[:safe?] in [true, "true"] or
      request.details[:risk] in [:low, "low"]
  end

  defp render_final({:ok, result}, output_fun, renderer) when is_map(result) do
    result
    |> then(&Renderer.render_final_report(renderer, &1))
    |> output_fun.()
  end

  defp render_final({:error, %Error{} = error}, output_fun, _renderer) do
    output_fun.("Final report\n  status: error\n  error: #{error.message}")
  end

  defp header_opts(%CliOptions{} = options, %Renderer{} = renderer) do
    %{
      session_id: options.session_id,
      cwd: options.cwd,
      agent: options.agent,
      model: options.model || "default",
      client: options.client_label || "default",
      mode: options.mode,
      profile: options.profile,
      toolsets: options.toolsets,
      approve: options.approve,
      detail: options.detail,
      jsonl_path: options.jsonl_path,
      sqlite_path: options.sqlite_path,
      persistence: options.persistence,
      renderer: renderer.name,
      theme: renderer.theme,
      color: renderer.color
    }
    |> Map.merge(Map.new(CliOptions.concurrency_opts(options)))
  end

  defp emit_model_preflight(%CliOptions{} = options, run_id, event_sink) do
    run_id = run_id || options.session_id

    event =
      Event.new!(:status,
        session_id: options.session_id,
        agent: options.agent,
        phase: :model_client_preflight,
        status: :ok,
        title: "Model/client resolved",
        detail: model_preflight_detail(options.model_resolution),
        data: %{
          requested_model: options.requested_model,
          model: options.model,
          client: options.client_label,
          run_id: run_id,
          model_resolution: options.model_resolution
        }
      )

    event_sink.(event)
  end

  defp model_preflight_detail(%{decision: decision, effective_model: effective_model}) do
    "#{decision}: #{effective_model}"
  end

  defp model_preflight_detail(_resolution), do: "resolved"

  defp field(nil, _key), do: nil
  defp field(%{__struct__: _struct} = map, key), do: Map.get(map, key)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_other, _key), do: nil
end
