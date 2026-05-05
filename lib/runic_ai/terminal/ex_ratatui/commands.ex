defmodule RunicAI.Terminal.ExRatatui.Commands do
  @moduledoc """
  Side-effecting operations for the ExRatatui workbench.
  """

  alias RunicAI.Persistence.Evals
  alias RunicAI.Persistence.Export
  alias RunicAI.Persistence.ManagedWorkflows
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Schemas.WorkflowRun
  alias RunicAI.Ids
  alias RunicAI.Terminal.AgentRunner
  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Options
  alias RunicAI.Terminal.ExRatatui.PersistenceView
  alias RunicAI.Terminal.ExRatatui.RenderCache

  @spec open_store(Options.t()) :: {:ok, Store.t() | nil, boolean()} | {:error, term()}
  def open_store(%Options{persistence: :none}), do: {:ok, nil, false}

  def open_store(%Options{persistence: :memory}) do
    case SQLite.open(database: ":memory:", migrate?: true) do
      {:ok, store} -> {:ok, store, true}
      {:error, reason} -> {:error, reason}
    end
  end

  def open_store(%Options{persistence: :sqlite, sqlite_path: path}) do
    case SQLite.open(database: path, migrate?: true) do
      {:ok, store} -> {:ok, store, true}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec close_store(Store.t() | nil, boolean()) :: :ok
  def close_store(%Store{} = store, true) do
    _ = SQLite.close(store)
    :ok
  end

  def close_store(_store, _owner?), do: :ok

  @spec load_snapshot(Model.t()) :: {:ok, map()} | {:error, term()}
  def load_snapshot(%Model{store: nil}) do
    {:ok,
     %{
       runs: [],
       timeline: [],
       messages: [],
       managed_workflows: [],
       eval_cohort: [],
       metrics: %{},
       signal_views: %{},
       status_message: "persistence disabled"
     }}
  end

  def load_snapshot(%Model{store: %Store{} = store} = model) do
    runs = Enum.map(Queries.recent_runs(store, limit: 50), &PersistenceView.run/1)

    selected_run_id =
      model.selected_run_id || model.run_id || (List.first(runs) && List.first(runs).id)

    selected = load_run_detail(store, selected_run_id)
    selected_run = Enum.find(runs, &(&1.id == selected_run_id))
    explicit_selection? = is_binary(model.selected_run_id || model.run_id)

    session_id =
      cond do
        explicit_selection? and not is_nil(selected_run) and not is_nil(selected_run.session_id) ->
          selected_run.session_id

        model.session_id ->
          model.session_id

        selected_run && selected_run.session_id ->
          selected_run.session_id

        true ->
          selected_run_id
      end

    managed = Enum.map(Queries.managed_workflows(store), &PersistenceView.managed_workflow/1)
    evals = Enum.map(Evals.cohort(store, limit: 20), &PersistenceView.eval_record/1)

    {:ok,
     selected
     |> Map.put(:messages, load_session_messages(store, session_id, selected.messages))
     |> Map.merge(%{
       runs: runs,
       session_id: session_id,
       selected_run_id: selected_run_id,
       managed_workflows: managed,
       eval_cohort: evals,
       metrics: Evals.compare_by_objective_status(store, limit: 50),
       signal_views: signal_views(selected, evals, managed),
       status_message: status_message(runs, selected_run_id)
     })}
  rescue
    exception -> {:error, exception}
  end

  @spec load_run_detail(Store.t(), String.t() | nil) :: map()
  def load_run_detail(_store, nil) do
    %{
      timeline: [],
      messages: [],
      runnable_events: [],
      failed_runnables: [],
      tool_calls: [],
      artifacts: [],
      scorecards: [],
      repairs: [],
      review_requests: []
    }
  end

  def load_run_detail(%Store{} = store, run_id) when is_binary(run_id) do
    %{
      timeline: Enum.map(Queries.run_timeline(store, run_id), &PersistenceView.terminal_event/1),
      messages: Enum.map(Queries.messages_for_run(store, run_id), &PersistenceView.message/1),
      runnable_events:
        Enum.map(Queries.runnable_events(store, run_id), &PersistenceView.runnable_event/1),
      failed_runnables:
        Enum.map(Queries.failed_runnables(store, run_id), &PersistenceView.runnable_event/1),
      tool_calls: Enum.map(Queries.tool_calls(store, run_id), &PersistenceView.tool_call/1),
      artifacts: Enum.map(Queries.artifacts_for_run(store, run_id), &PersistenceView.artifact/1),
      scorecards:
        Enum.map(Queries.scorecards_for_run(store, run_id), &PersistenceView.scorecard/1),
      repairs:
        Enum.map(Queries.repair_attempts(store, run_id), &PersistenceView.repair_attempt/1),
      review_requests:
        Enum.map(Queries.review_requests(store, run_id), &PersistenceView.review_request/1)
    }
  end

  @spec search(Model.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def search(%Model{store: nil}, term), do: {:ok, %{search_term: term, search_results: []}}

  def search(%Model{store: %Store{} = store}, term) when is_binary(term) do
    events =
      store
      |> Queries.search_events(term)
      |> Enum.map(&PersistenceView.terminal_event/1)

    {:ok, %{search_term: term, search_results: events, status_message: "search: #{term}"}}
  rescue
    exception -> {:error, exception}
  end

  @spec export_run(Model.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def export_run(%Model{store: nil}, _path), do: {:error, :persistence_disabled}
  def export_run(%Model{selected_run_id: nil}, _path), do: {:error, :no_selected_run}

  def export_run(%Model{store: %Store{} = store, selected_run_id: run_id, cwd: cwd}, path) do
    path = path || Path.join(cwd, "tmp/runic_ai_#{safe_id(run_id)}.jsonl")

    case Export.write_terminal_jsonl(store, run_id, path) do
      :ok -> {:ok, %{last_export_path: path, status_message: "exported #{run_id}"}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rename_run(Model.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rename_run(%Model{store: nil}, _title), do: {:error, :persistence_disabled}
  def rename_run(%Model{selected_run_id: nil}, _title), do: {:error, :no_selected_run}

  def rename_run(%Model{store: %Store{} = store, selected_run_id: run_id} = model, title)
      when is_binary(title) do
    SQLite.with_repo(store, fn ->
      case store.repo.get(WorkflowRun, run_id) do
        nil ->
          {:error, :not_found}

        run ->
          metadata =
            run.metadata_json
            |> Kernel.||(%{})
            |> Map.put("title", title)

          run
          |> WorkflowRun.changeset(%{workflow_name: title, metadata_json: metadata})
          |> store.repo.update()
          |> case do
            {:ok, _run} -> load_snapshot(%{model | status_message: "renamed #{run_id}"})
            {:error, changeset} -> {:error, changeset}
          end
      end
    end)
  rescue
    exception -> {:error, exception}
  end

  @spec apply_review_decision(Model.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def apply_review_decision(%Model{store: nil}, _decision), do: {:error, :persistence_disabled}

  def apply_review_decision(%Model{} = model, decision) when is_binary(decision) do
    with %{} = review <- Model.selected_review(model),
         {:ok, event} <- review_event(model, review, decision),
         {:ok, _row} <- SQLite.record_terminal_event(model.store, event) do
      load_snapshot(%{model | selected_review_id: review.id})
    else
      nil -> {:error, :no_selected_review}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_agent_run(Model.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def start_agent_run(%Model{} = model, objective) when is_binary(objective) do
    session_id = model.session_id || Ids.unique("#{model.agent}:tui")
    run_id = Ids.unique("#{model.agent}:tui")
    history = conversation_history(model, session_id)

    args =
      [
        objective,
        "--agent",
        Atom.to_string(model.agent),
        "--cwd",
        model.cwd,
        "--mode",
        model.mode |> Atom.to_string() |> String.replace("_", "-"),
        "--approve",
        Atom.to_string(model.approve),
        "--persistence",
        "none"
      ]
      |> maybe_arg("--model", model.model)
      |> maybe_arg("--session-id", session_id)

    with {:ok, options} <- CliOptions.parse(args),
         :ok <- persist_user_message(model, session_id, run_id, objective),
         {:ok, result} <-
           AgentRunner.run(options,
             persistence: model.store,
             run_id: run_id,
             conversation_history: history,
             run_fun: model.run_fun,
             output_fun: fn _line -> :ok end
           ) do
      load_snapshot(%{model | session_id: session_id, selected_run_id: result[:run_id] || run_id})
    end
  end

  @spec record_stream_update(Model.t(), map(), boolean()) :: {:ok, map()} | {:error, term()}
  def record_stream_update(%Model{store: nil}, _attrs, _complete?), do: {:ok, %{}}

  def record_stream_update(%Model{store: %Store{} = store} = model, attrs, complete?)
      when is_map(attrs) do
    run_id =
      stream_value(attrs, :run_id) || model.selected_run_id || model.run_id || model.session_id

    content = stream_value(attrs, :content) || stream_value(attrs, :chunk) || ""
    stream_id = stream_value(attrs, :stream_id) || stream_value(attrs, :message_id)
    stream_status = stream_status(attrs, complete?)
    kind = if complete? or terminal_stream_status?(stream_status), do: :message, else: :chunk
    phase = stream_phase(stream_status, complete?)

    event =
      Event.new!(kind,
        session_id: run_id,
        agent: model.agent,
        phase: phase,
        status: terminal_status(stream_status, complete?),
        title: stream_title(stream_status, complete?),
        detail: content,
        data: %{
          run_id: run_id,
          stream_id: stream_id,
          role: "assistant",
          message_kind: stream_message_kind(stream_status),
          content: content,
          error: stream_error(attrs, stream_status)
        }
      )

    case SQLite.record_terminal_event(store, event) do
      {:ok, _row} ->
        if complete? or terminal_stream_status?(stream_status) do
          case load_snapshot(%{model | selected_run_id: run_id, run_id: run_id}) do
            {:ok, snapshot} -> {:ok, %{reload_snapshot: snapshot}}
            {:error, reason} -> {:error, reason}
          end
        else
          {:ok, %{}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  @spec render_graphs(Model.t()) :: {:ok, map()} | {:error, term()}
  def render_graphs(%Model{} = model) do
    sources = Model.graph_sources(model)
    markdown_sources = RenderCache.markdown_sources(model)

    cache =
      model.render_cache
      |> RenderCache.render_markdown_sources(markdown_sources,
        width: :auto,
        theme: model.theme
      )
      |> RenderCache.render_graph_sources(sources,
        mode: model.graph,
        theme: model.theme
      )

    {:ok,
     %{
       render_cache: cache,
       status_message: graph_render_status(model, sources, markdown_sources)
     }}
  rescue
    exception -> {:error, exception}
  end

  defp persist_user_message(%Model{store: nil}, _session_id, _run_id, _objective), do: :ok

  defp persist_user_message(
         %Model{store: %Store{} = store} = model,
         session_id,
         run_id,
         objective
       ) do
    event =
      Event.new!(:message,
        session_id: session_id,
        agent: model.agent,
        phase: :user,
        status: :ok,
        title: "User request",
        detail: objective,
        data: %{
          run_id: run_id,
          role: "user",
          message_kind: "objective",
          content: objective,
          objective: objective,
          conversation_id: "conversation:#{session_id}",
          cwd: model.cwd,
          model: model.model
        }
      )

    case SQLite.record_terminal_event(store, event) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_session_messages(_store, nil, fallback), do: fallback

  defp load_session_messages(%Store{} = store, session_id, fallback) when is_binary(session_id) do
    messages =
      store
      |> Queries.conversation_messages("conversation:#{session_id}")
      |> Enum.map(&PersistenceView.message/1)

    case messages do
      [] -> fallback
      messages -> messages
    end
  end

  defp conversation_history(%Model{store: nil}, _session_id), do: []

  defp conversation_history(%Model{store: %Store{} = store}, session_id)
       when is_binary(session_id) do
    store
    |> Queries.conversation_messages("conversation:#{session_id}")
    |> Enum.reject(& &1.transient)
    |> Enum.reject(&summary_message?/1)
    |> Enum.take(-12)
    |> Enum.map(&history_message/1)
    |> Enum.reject(&(String.trim(&1.content) == ""))
  end

  defp conversation_history(%Model{}, _session_id), do: []

  defp history_message(message) do
    %{
      role: message.role,
      message_kind: message.message_kind,
      content: message.content || "",
      created_at: message.created_at
    }
  end

  defp summary_message?(message),
    do: message.role == "assistant" and message.message_kind in ["summary"]

  @spec managed_workflows(Model.t(), atom() | String.t() | nil) :: {:ok, map()} | {:error, term()}
  def managed_workflows(%Model{store: nil}, _status), do: {:ok, %{managed_workflows: []}}

  def managed_workflows(%Model{store: %Store{} = store}, status) do
    opts = if is_nil(status), do: [], else: [status: status]

    workflows =
      store |> Queries.managed_workflows(opts) |> Enum.map(&PersistenceView.managed_workflow/1)

    {:ok, %{managed_workflows: workflows, status_message: "managed workflows loaded"}}
  rescue
    exception -> {:error, exception}
  end

  @spec eval_cohort(Model.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def eval_cohort(%Model{store: nil}, _status), do: {:ok, %{eval_cohort: []}}

  def eval_cohort(%Model{store: %Store{} = store}, objective_status) do
    opts =
      if is_binary(objective_status) and objective_status != "" do
        [objective_status: objective_status, limit: 50]
      else
        [limit: 50]
      end

    cohort = store |> Evals.cohort(opts) |> Enum.map(&PersistenceView.eval_record/1)
    {:ok, %{eval_cohort: cohort, metrics: Evals.compare_by_objective_status(store, opts)}}
  rescue
    exception -> {:error, exception}
  end

  @spec start_managed_workflow(Model.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def start_managed_workflow(%Model{store: nil}, _workflow_key),
    do: {:error, :persistence_disabled}

  def start_managed_workflow(%Model{store: %Store{} = store} = model, workflow_key) do
    with {:ok, workflow} <- selected_workflow(store, model, workflow_key),
         {:ok, run} <-
           ManagedWorkflows.create_run(store, workflow.workflow_key,
             trigger: :manual,
             status: :pending,
             metadata: %{source: "runic_ai.tui"}
           ),
         :ok <- maybe_call_managed_start(model, workflow, run) do
      load_snapshot(%{
        model
        | selected_run_id: run.id,
          status_message: "started managed workflow #{workflow.workflow_key}"
      })
    end
  rescue
    exception -> {:error, exception}
  end

  @spec resume_workflow(Model.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def resume_workflow(%Model{store: nil}, _workflow_key), do: {:error, :persistence_disabled}

  def resume_workflow(%Model{store: %Store{} = store} = model, workflow_key) do
    with {:ok, workflow} <- selected_workflow(store, model, workflow_key),
         :ok <- maybe_call_resume(model, workflow) do
      {:ok,
       %{
         status_message:
           "resume requested for #{workflow.workflow_key}; " <>
             resume_status(model.resume_fun)
       }}
    end
  end

  defp selected_workflow(_store, %Model{managed_workflows: []}, nil),
    do: {:error, :no_managed_workflow}

  defp selected_workflow(%Store{} = store, %Model{} = model, nil) do
    model.managed_workflows
    |> List.first()
    |> workflow_key()
    |> then(&selected_workflow(store, model, &1))
  end

  defp selected_workflow(_store, _model, nil), do: {:error, :no_managed_workflow}

  defp selected_workflow(%Store{} = store, _model, workflow_key) when is_binary(workflow_key) do
    case ManagedWorkflows.get(store, workflow_key) do
      nil -> {:error, :not_found}
      workflow -> {:ok, workflow}
    end
  end

  defp maybe_call_managed_start(%Model{managed_start_fun: nil}, _workflow, _run), do: :ok

  defp maybe_call_managed_start(%Model{managed_start_fun: fun} = model, workflow, run)
       when is_function(fun, 3) do
    case fun.(model, workflow, run) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_managed_start_result, other}}
    end
  end

  defp maybe_call_resume(%Model{resume_fun: nil}, _workflow), do: :ok

  defp maybe_call_resume(%Model{resume_fun: fun} = model, workflow) when is_function(fun, 2) do
    case fun.(model, workflow) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_resume_result, other}}
    end
  end

  defp resume_status(nil), do: "no live runner attached"
  defp resume_status(_fun), do: "delegated to live runner"

  defp workflow_key(%{workflow_key: key}) when is_binary(key), do: key
  defp workflow_key(%{id: id}) when is_binary(id), do: id
  defp workflow_key(_workflow), do: nil

  defp review_event(%Model{} = model, review, decision) do
    status = if decision in ["approve", "approved", "allow"], do: :ok, else: :blocked

    Event.new(:hitl,
      session_id: review.session_id || model.selected_run_id,
      agent: model.agent,
      phase: :review_decision,
      status: status,
      title: "Review #{decision}",
      detail: "review #{review.id} #{decision}",
      data: %{
        id: review.id,
        run_id: review.workflow_run_id || model.selected_run_id,
        kind: review.kind,
        checkpoint: review.checkpoint,
        resume_key: review.resume_key,
        decision: %{decision: decision, decided_at: DateTime.utc_now()}
      }
    )
  end

  defp status_message([], _selected_run_id), do: "no durable runs yet"
  defp status_message(_runs, nil), do: "select a run"
  defp status_message(_runs, selected_run_id), do: "loaded #{selected_run_id}"

  defp graph_render_status(%Model{graph: graph}, [], []),
    do: "graph: #{graph}; no render sources"

  defp graph_render_status(%Model{graph: graph}, sources, markdown_sources),
    do: "graph: #{graph}; #{length(sources)} graph(s), #{length(markdown_sources)} markdown"

  defp signal_views(selected, evals, managed) do
    %{
      prefetch_candidates: Enum.take(Map.get(selected, :artifacts, []), 5),
      session_recall: Enum.take(Map.get(selected, :timeline, []), -5),
      sync_turn_facts: Enum.take(Map.get(selected, :runnable_events, []), -5),
      delegation_summaries: Enum.take(Map.get(selected, :tool_calls, []), -5),
      on_session_end_summaries: Enum.take(evals, 5),
      managed_workflow_signals: Enum.take(managed, 5)
    }
  end

  defp safe_id(id), do: String.replace(id, ~r/[^A-Za-z0-9_.-]/, "_")

  defp stream_value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp stream_status(attrs, true) do
    attrs
    |> stream_value(:status)
    |> case do
      nil -> "ok"
      status -> to_string(status)
    end
  end

  defp stream_status(attrs, false) do
    attrs
    |> stream_value(:status)
    |> case do
      nil -> "running"
      status -> to_string(status)
    end
  end

  defp terminal_stream_status?(status), do: status in ["error", "failed", "interrupted"]

  defp terminal_status(status, _complete?) when status in ["error", "failed"], do: :error
  defp terminal_status("interrupted", _complete?), do: :blocked
  defp terminal_status(_status, true), do: :ok
  defp terminal_status(_status, false), do: :running

  defp stream_phase(status, _complete?) when status in ["error", "failed"],
    do: :assistant_stream_failed

  defp stream_phase("interrupted", _complete?), do: :assistant_stream_interrupted
  defp stream_phase(_status, true), do: :assistant
  defp stream_phase(_status, false), do: :assistant_chunk

  defp stream_title(status, _complete?) when status in ["error", "failed"],
    do: "Assistant stream failed"

  defp stream_title("interrupted", _complete?), do: "Assistant stream interrupted"
  defp stream_title(_status, true), do: "Assistant stream complete"
  defp stream_title(_status, false), do: "Assistant stream chunk"

  defp stream_message_kind(status) when status in ["error", "failed"], do: "stream_error"
  defp stream_message_kind("interrupted"), do: "stream_interrupted"
  defp stream_message_kind(_status), do: "stream"

  defp stream_error(attrs, status) when status in ["error", "failed", "interrupted"] do
    reason = stream_value(attrs, :reason) || stream_value(attrs, :error) || status
    %{message: to_string(reason), status: status}
  end

  defp stream_error(_attrs, _status), do: %{}

  defp maybe_arg(args, _flag, nil), do: args
  defp maybe_arg(args, _flag, ""), do: args
  defp maybe_arg(args, flag, value), do: args ++ [flag, value]
end
