defmodule RunicAI.Terminal.ExRatatui.Model do
  @moduledoc """
  Pure state for the ExRatatui workbench.
  """

  alias RunicAI.Ids
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Terminal.ExRatatui.CommandSuggestions
  alias RunicAI.Terminal.ExRatatui.Options
  alias RunicAI.Terminal.ExRatatui.RenderCache
  alias RunicAI.Terminal.StreamBuffer

  @chat_focus_order [:conversation, :composer]
  @debug_focus_order [:runs, :timeline, :details, :managed, :evals, :composer]
  @conversation_page_rows 12
  @conversation_home_rows 1_000_000

  @enforce_keys [:cwd, :persistence, :agent, :approve, :mode, :theme, :graph]
  defstruct [
    :options,
    :store,
    :sqlite_path,
    :run_id,
    :selected_run_id,
    :selected_event_id,
    :selected_message_id,
    :selected_review_id,
    :composer_ref,
    :slash_ref,
    :model,
    :requested_model,
    :model_resolution,
    :client,
    :client_label,
    :session_id,
    :ssh_port,
    :run_fun,
    :managed_start_fun,
    :resume_fun,
    :last_export_path,
    :search_term,
    :error,
    :status_message,
    :log_filter_level,
    :log_filter_source,
    :detail_mode,
    :pending_composer_submit_id,
    runs: [],
    timeline: [],
    messages: [],
    runnable_events: [],
    failed_runnables: [],
    tool_calls: [],
    artifacts: [],
    scorecards: [],
    repairs: [],
    review_requests: [],
    objective_loop: nil,
    progress_summary: %{},
    managed_workflows: [],
    eval_cohort: [],
    search_results: [],
    logs: [],
    render_cache: %{},
    stream_buffers: %{},
    suggestions: [],
    suggestion_index: 0,
    composer_history: [],
    composer_history_index: nil,
    composer_history_draft: "",
    conversation_scrollback_rows: 0,
    conversation_search: nil,
    pinned_message_ids: MapSet.new(),
    signal_views: %{},
    metrics: %{},
    view_mode: :chat,
    focus: :conversation,
    slash_mode?: false,
    slash_text: "",
    composer_text: "",
    active_run?: false,
    store_owner?: false,
    detail_visible?: true,
    cwd: nil,
    persistence: :sqlite,
    agent: :assistant,
    approve: :ask,
    mode: :verify,
    theme: :runic,
    graph: :text,
    status: :booting
  ]

  @type t :: %__MODULE__{}

  @spec new(Options.t(), keyword()) :: t()
  def new(%Options{} = options, opts \\ []) do
    %__MODULE__{
      options: options,
      store: Keyword.get(opts, :store),
      store_owner?: Keyword.get(opts, :store_owner?, false),
      cwd: options.cwd,
      persistence: options.persistence,
      sqlite_path: options.sqlite_path,
      run_id: options.run_id,
      selected_run_id: options.run_id,
      agent: options.agent,
      model: options.model,
      requested_model: options.requested_model,
      model_resolution: options.model_resolution,
      client: options.client,
      client_label: options.client_label,
      approve: options.approve,
      mode: options.mode,
      session_id: options.session_id || options.run_id || Ids.unique("#{options.agent}:tui"),
      theme: options.theme,
      graph: options.graph,
      ssh_port: options.ssh_port,
      detail_mode: :summary,
      status_message: "loading durable runs",
      composer_ref: Keyword.get(opts, :composer_ref),
      slash_ref: Keyword.get(opts, :slash_ref),
      run_fun: Keyword.get(opts, :run_fun),
      managed_start_fun: Keyword.get(opts, :managed_start_fun),
      resume_fun: Keyword.get(opts, :resume_fun)
    }
  end

  @spec put_store(t(), Store.t() | nil, boolean()) :: t()
  def put_store(%__MODULE__{} = model, store, owner?) do
    %{model | store: store, store_owner?: owner?}
  end

  @spec apply_snapshot(t(), map()) :: t()
  def apply_snapshot(%__MODULE__{} = model, snapshot) when is_map(snapshot) do
    messages = Map.get(snapshot, :messages, [])
    timeline = Map.get(snapshot, :timeline, [])

    selected_run_id =
      Map.get(snapshot, :selected_run_id) ||
        model.selected_run_id ||
        snapshot |> Map.get(:runs, []) |> List.first() |> then(&(&1 && &1.id))

    selected_event_id =
      if Enum.any?(timeline, &(&1.id == model.selected_event_id)) do
        model.selected_event_id
      else
        timeline |> List.last() |> then(&(&1 && &1.id))
      end

    selected_message_id =
      if Enum.any?(messages, &(&1.id == model.selected_message_id)) do
        model.selected_message_id
      else
        messages |> List.last() |> then(&(&1 && &1.id))
      end

    %{
      model
      | runs: Map.get(snapshot, :runs, []),
        timeline: timeline,
        messages: messages,
        runnable_events: Map.get(snapshot, :runnable_events, []),
        failed_runnables: Map.get(snapshot, :failed_runnables, []),
        tool_calls: Map.get(snapshot, :tool_calls, []),
        artifacts: Map.get(snapshot, :artifacts, []),
        scorecards: Map.get(snapshot, :scorecards, []),
        repairs: Map.get(snapshot, :repairs, []),
        review_requests: Map.get(snapshot, :review_requests, []),
        objective_loop: Map.get(snapshot, :objective_loop),
        progress_summary: Map.get(snapshot, :progress_summary, %{}),
        managed_workflows: Map.get(snapshot, :managed_workflows, []),
        eval_cohort: Map.get(snapshot, :eval_cohort, []),
        search_results: Map.get(snapshot, :search_results, model.search_results),
        render_cache: Map.get(snapshot, :render_cache, model.render_cache),
        signal_views: Map.get(snapshot, :signal_views, %{}),
        metrics: Map.get(snapshot, :metrics, %{}),
        session_id: Map.get(snapshot, :session_id, model.session_id),
        selected_run_id: selected_run_id,
        selected_event_id: selected_event_id,
        selected_message_id: selected_message_id,
        selected_review_id:
          model.selected_review_id ||
            snapshot
            |> Map.get(:review_requests, [])
            |> Enum.find(&(&1.status == "pending"))
            |> then(&(&1 && &1.id)),
        status: :ready,
        status_message: Map.get(snapshot, :status_message, "ready"),
        error: nil
    }
  end

  @spec put_error(t(), term()) :: t()
  def put_error(%__MODULE__{} = model, reason) do
    %{model | status: :error, error: reason, status_message: error_message(reason)}
  end

  @spec selected_run(t()) :: map() | nil
  def selected_run(%__MODULE__{} = model) do
    Enum.find(model.runs, &(&1.id == model.selected_run_id))
  end

  @spec selected_event(t()) :: map() | nil
  def selected_event(%__MODULE__{} = model) do
    Enum.find(model.timeline, &(&1.id == model.selected_event_id))
  end

  @spec selected_message(t()) :: map() | nil
  def selected_message(%__MODULE__{} = model) do
    Enum.find(model.messages, &(&1.id == model.selected_message_id))
  end

  @spec selected_review(t()) :: map() | nil
  def selected_review(%__MODULE__{} = model) do
    Enum.find(model.review_requests, &(&1.id == model.selected_review_id))
  end

  @spec cycle_focus(t(), :next | :prev) :: t()
  def cycle_focus(%__MODULE__{} = model, direction) do
    order = focus_order(model)
    current = Enum.find_index(order, &(&1 == model.focus)) || 0
    size = length(order)

    next =
      case direction do
        :prev -> rem(current - 1 + size, size)
        :next -> rem(current + 1, size)
      end

    %{model | focus: Enum.at(order, next)}
  end

  @spec move_selection(t(), integer()) :: t()
  def move_selection(%__MODULE__{focus: :runs} = model, delta) do
    id = move_id(model.runs, model.selected_run_id, delta)
    %{model | selected_run_id: id, selected_event_id: nil, selected_message_id: nil}
  end

  def move_selection(%__MODULE__{focus: :conversation} = model, delta) do
    %{
      model
      | selected_message_id: move_id(model.messages, model.selected_message_id, delta),
        conversation_scrollback_rows: 0
    }
  end

  def move_selection(%__MODULE__{focus: :timeline} = model, delta) do
    %{model | selected_event_id: move_id(model.timeline, model.selected_event_id, delta)}
  end

  def move_selection(%__MODULE__{focus: :details} = model, delta) do
    %{model | selected_event_id: move_id(model.timeline, model.selected_event_id, delta)}
  end

  def move_selection(%__MODULE__{} = model, _delta), do: model

  @spec set_composer_text(t(), String.t()) :: t()
  def set_composer_text(%__MODULE__{} = model, text) when is_binary(text) do
    %{model | composer_text: text}
  end

  @spec clear_composer(t()) :: t()
  def clear_composer(%__MODULE__{} = model) do
    %{
      model
      | composer_text: "",
        slash_text: "",
        slash_mode?: false,
        pending_composer_submit_id: nil,
        composer_history_index: nil,
        composer_history_draft: ""
    }
    |> clear_suggestions()
  end

  @spec remember_composer_submission(t(), String.t()) :: t()
  def remember_composer_submission(%__MODULE__{} = model, text) when is_binary(text) do
    text = String.trim(text)

    history =
      if text == "" do
        model.composer_history
      else
        model.composer_history
        |> reject_latest_duplicate(text)
        |> Kernel.++([text])
        |> Enum.take(-100)
      end

    %{
      model
      | composer_history: history,
        composer_history_index: nil,
        composer_history_draft: ""
    }
  end

  @spec navigate_composer_history(t(), :prev | :next, String.t()) :: {t(), String.t() | nil}
  def navigate_composer_history(%__MODULE__{composer_history: []} = model, _direction, _draft) do
    {model, nil}
  end

  def navigate_composer_history(%__MODULE__{} = model, direction, draft) when is_binary(draft) do
    history_size = length(model.composer_history)
    current_index = model.composer_history_index
    draft = if is_nil(current_index), do: draft, else: model.composer_history_draft

    next_index =
      case {direction, current_index} do
        {:prev, nil} -> history_size - 1
        {:prev, index} -> max(index - 1, 0)
        {:next, nil} -> nil
        {:next, index} when index >= history_size - 1 -> nil
        {:next, index} -> index + 1
      end

    text =
      case next_index do
        nil -> draft
        index -> Enum.at(model.composer_history, index)
      end

    model = %{
      model
      | composer_history_index: next_index,
        composer_history_draft: draft,
        composer_text: text
    }

    {model, text}
  end

  @spec reset_composer_history_navigation(t()) :: t()
  def reset_composer_history_navigation(%__MODULE__{} = model) do
    %{model | composer_history_index: nil, composer_history_draft: ""}
  end

  @spec set_slash_text(t(), String.t()) :: t()
  def set_slash_text(%__MODULE__{} = model, text) when is_binary(text) do
    %{model | slash_text: text, slash_mode?: true}
    |> put_suggestions(text)
  end

  @spec put_suggestions(t(), String.t()) :: t()
  def put_suggestions(%__MODULE__{} = model, text) when is_binary(text) do
    suggestions = CommandSuggestions.suggest(model, text)

    %{
      model
      | suggestions: suggestions,
        suggestion_index: min(model.suggestion_index || 0, max(length(suggestions) - 1, 0))
    }
  end

  @spec clear_suggestions(t()) :: t()
  def clear_suggestions(%__MODULE__{} = model) do
    %{model | suggestions: [], suggestion_index: 0}
  end

  @spec move_suggestion(t(), :next | :prev) :: t()
  def move_suggestion(%__MODULE__{} = model, direction) do
    %{
      model
      | suggestion_index:
          CommandSuggestions.next_index(model.suggestions, model.suggestion_index, direction)
    }
  end

  @spec selected_suggestion(t()) :: map() | nil
  def selected_suggestion(%__MODULE__{} = model) do
    CommandSuggestions.selected(model.suggestions, model.suggestion_index)
  end

  @spec scroll_conversation(t(), :up | :down | :page_up | :page_down | :home | :end) :: t()
  def scroll_conversation(%__MODULE__{} = model, action) do
    rows =
      case action do
        :up -> model.conversation_scrollback_rows + 1
        :down -> model.conversation_scrollback_rows - 1
        :page_up -> model.conversation_scrollback_rows + @conversation_page_rows
        :page_down -> model.conversation_scrollback_rows - @conversation_page_rows
        :home -> @conversation_home_rows
        :end -> 0
      end

    rows = max(rows, 0)

    %{
      model
      | conversation_scrollback_rows: rows,
        status_message: conversation_scroll_status(action, rows)
    }
  end

  @spec put_render_cache(t(), map()) :: t()
  def put_render_cache(%__MODULE__{} = model, cache) when is_map(cache) do
    %{model | render_cache: cache}
  end

  @spec graph_sources(t()) :: [map()]
  def graph_sources(%__MODULE__{} = model), do: RenderCache.graph_sources(model)

  @spec append_stream(t(), map()) :: t()
  def append_stream(%__MODULE__{} = model, attrs) when is_map(attrs) do
    {buffers, message} = StreamBuffer.append(model.stream_buffers, attrs)
    messages = upsert_message(model.messages, message)

    selected_message_id =
      if follow_latest_message?(model), do: message.id, else: model.selected_message_id

    %{
      model
      | stream_buffers: buffers,
        messages: messages,
        selected_message_id: selected_message_id,
        status_message: stream_status_message(message)
    }
  end

  @spec finalize_stream(t(), map()) :: t()
  def finalize_stream(%__MODULE__{} = model, attrs) when is_map(attrs) do
    {buffers, message} = StreamBuffer.finalize(model.stream_buffers, attrs)

    selected_message_id =
      if follow_latest_message?(model), do: message.id, else: model.selected_message_id

    %{
      model
      | stream_buffers: buffers,
        messages: upsert_message(model.messages, message),
        selected_message_id: selected_message_id,
        status_message: "stream complete"
    }
  end

  @spec fail_stream(t(), map()) :: t()
  def fail_stream(%__MODULE__{} = model, attrs) when is_map(attrs) do
    {buffers, message} = StreamBuffer.fail(model.stream_buffers, attrs)
    messages = upsert_message(model.messages, message)

    selected_message_id =
      if follow_latest_message?(model), do: message.id, else: model.selected_message_id

    %{
      model
      | stream_buffers: buffers,
        messages: messages,
        selected_message_id: selected_message_id,
        status_message: stream_status_message(message)
    }
  end

  @spec interrupt_stream(t(), map()) :: t()
  def interrupt_stream(%__MODULE__{} = model, attrs) when is_map(attrs) do
    {buffers, message} = StreamBuffer.interrupt(model.stream_buffers, attrs)
    messages = upsert_message(model.messages, message)

    selected_message_id =
      if follow_latest_message?(model), do: message.id, else: model.selected_message_id

    %{
      model
      | stream_buffers: buffers,
        messages: messages,
        selected_message_id: selected_message_id,
        status_message: stream_status_message(message)
    }
  end

  @spec append_log(t(), map()) :: t()
  def append_log(%__MODULE__{} = model, log) when is_map(log) do
    %{model | logs: Enum.take(model.logs ++ [log], -200)}
  end

  @spec put_log_filter(t(), String.t() | nil) :: t()
  def put_log_filter(%__MODULE__{} = model, nil) do
    %{model | log_filter_level: nil, log_filter_source: nil, status_message: "logs: all"}
  end

  def put_log_filter(%__MODULE__{} = model, value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value in ["", "all", "clear"] ->
        put_log_filter(model, nil)

      String.starts_with?(value, ["source:", "src:"]) ->
        source = value |> String.split(":", parts: 2) |> List.last() |> String.trim()

        %{
          model
          | log_filter_level: nil,
            log_filter_source: source,
            status_message: "logs: source #{source}"
        }

      true ->
        level = String.downcase(value)

        %{
          model
          | log_filter_level: level,
            log_filter_source: nil,
            status_message: "logs: #{level}"
        }
    end
  end

  @spec filtered_logs(t()) :: [map()]
  def filtered_logs(%__MODULE__{} = model) do
    Enum.filter(model.logs, fn log ->
      log_level_matches?(log, model.log_filter_level) and
        log_source_matches?(log, model.log_filter_source)
    end)
  end

  @spec put_detail_mode(t(), :summary | :prompt_context) :: t()
  def put_detail_mode(%__MODULE__{} = model, mode) when mode in [:summary, :prompt_context] do
    %{model | detail_mode: mode}
  end

  @spec slash_input(t()) :: String.t()
  def slash_input(%__MODULE__{} = model) do
    if model.slash_mode?, do: model.slash_text, else: model.composer_text
  end

  @spec put_view_mode(t(), :chat | :debug) :: t()
  def put_view_mode(%__MODULE__{} = model, mode) when mode in [:chat, :debug] do
    focus = model.focus
    order = focus_order(mode)

    %{model | view_mode: mode, focus: if(focus in order, do: focus, else: List.first(order))}
  end

  @spec toggle_view_mode(t()) :: t()
  def toggle_view_mode(%__MODULE__{view_mode: :chat} = model), do: put_view_mode(model, :debug)
  def toggle_view_mode(%__MODULE__{} = model), do: put_view_mode(model, :chat)

  @spec new_thread(t(), String.t() | nil) :: t()
  def new_thread(%__MODULE__{} = model, run_id \\ nil) do
    run_id = run_id || RunicAI.Ids.unique("#{model.agent}:tui")

    %{
      model
      | session_id: run_id,
        run_id: run_id,
        selected_run_id: run_id,
        selected_event_id: nil,
        selected_message_id: nil,
        selected_review_id: nil,
        messages: [],
        timeline: [],
        runnable_events: [],
        failed_runnables: [],
        tool_calls: [],
        artifacts: [],
        scorecards: [],
        repairs: [],
        review_requests: [],
        search_results: [],
        conversation_scrollback_rows: 0,
        conversation_search: nil,
        status_message: "new conversation #{run_id}"
    }
  end

  @spec focus_order(t() | :chat | :debug) :: [atom()]
  def focus_order(%__MODULE__{view_mode: mode}), do: focus_order(mode)
  def focus_order(:chat), do: @chat_focus_order
  def focus_order(:debug), do: @debug_focus_order

  defp move_id([], _current_id, _delta), do: nil

  defp move_id(rows, current_id, delta) do
    current = Enum.find_index(rows, &(&1.id == current_id)) || 0
    next = current + delta
    next = max(0, min(next, length(rows) - 1))
    Enum.at(rows, next).id
  end

  defp reject_latest_duplicate(history, text) do
    case List.last(history) do
      ^text -> Enum.drop(history, -1)
      _other -> history
    end
  end

  defp upsert_message(messages, message) do
    case Enum.find_index(messages, &(&1.id == message.id)) do
      nil -> messages ++ [message]
      index -> List.replace_at(messages, index, message)
    end
  end

  defp follow_latest_message?(%__MODULE__{messages: []}), do: true

  defp follow_latest_message?(%__MODULE__{} = model) do
    last = List.last(model.messages)

    model.conversation_scrollback_rows == 0 and
      (is_nil(model.selected_message_id) or (last && last.id == model.selected_message_id))
  end

  defp conversation_scroll_status(:home, _rows), do: "conversation: top"
  defp conversation_scroll_status(:end, _rows), do: "conversation: tail"
  defp conversation_scroll_status(_action, 0), do: "conversation: tail"
  defp conversation_scroll_status(_action, rows), do: "conversation: #{rows} rows back"

  defp stream_status_message(%{content_json: %{status: status}})
       when status in ["error", "failed"],
       do: "stream failed"

  defp stream_status_message(%{content_json: %{status: "interrupted"}}),
    do: "stream interrupted"

  defp stream_status_message(%{stream_complete: true}), do: "stream complete"
  defp stream_status_message(_message), do: "streaming"

  defp log_level_matches?(_log, nil), do: true

  defp log_level_matches?(log, level) do
    log
    |> Map.get(:level, Map.get(log, "level"))
    |> to_string()
    |> String.downcase()
    |> Kernel.==(level)
  end

  defp log_source_matches?(_log, nil), do: true
  defp log_source_matches?(_log, ""), do: true

  defp log_source_matches?(log, source) do
    log
    |> Map.get(:source, Map.get(log, "source", ""))
    |> to_string()
    |> String.downcase()
    |> String.contains?(String.downcase(source))
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(reason), do: inspect(reason)
end
