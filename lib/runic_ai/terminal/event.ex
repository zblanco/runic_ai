defmodule RunicAI.Terminal.Event do
  @moduledoc """
  Presentation-neutral terminal event contract.

  Terminal runners normalize backend/runtime activity into this struct before
  any CLI, JSONL, or future TUI renderer sees it. The struct intentionally keeps
  `raw` for in-memory debugging while `to_json_map/2` emits only JSON-safe data.
  """

  alias RunicAI.Error
  alias RunicAI.Harness.Session
  alias RunicAI.Ids
  alias RunicAI.ReviewRequest
  alias RunicAI.Trace.Event, as: TraceEvent
  alias RunicAI.Wait

  @agents [:standard, :rlm, :assistant]

  @kinds [
    :status,
    :message,
    :tool,
    :hitl,
    :rlm_plan,
    :rlm_node,
    :verification,
    :repair,
    :subagent,
    :chunk,
    :error,
    :summary
  ]

  @statuses [:pending, :running, :ok, :review, :waiting, :blocked, :error]

  @enforce_keys [:id, :at, :agent, :kind, :status, :title, :data]
  defstruct [
    :id,
    :at,
    :session_id,
    :agent,
    :kind,
    :phase,
    :status,
    :title,
    :detail,
    data: %{},
    raw: nil
  ]

  @type agent :: :standard | :rlm | :assistant
  @type kind ::
          :status
          | :message
          | :tool
          | :hitl
          | :rlm_plan
          | :rlm_node
          | :verification
          | :repair
          | :subagent
          | :chunk
          | :error
          | :summary
  @type status :: :pending | :running | :ok | :review | :waiting | :blocked | :error

  @type t :: %__MODULE__{
          id: String.t(),
          at: DateTime.t(),
          session_id: String.t() | nil,
          agent: agent(),
          kind: kind(),
          phase: atom() | nil,
          status: status(),
          title: String.t(),
          detail: String.t() | nil,
          data: map(),
          raw: term()
        }

  @spec new(kind(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, opts \\ []) when is_list(opts) do
    data = Keyword.get(opts, :data, %{})

    with {:ok, normalized_kind} <- normalize_kind(kind),
         {:ok, agent} <- normalize_agent(Keyword.get(opts, :agent, :standard)),
         {:ok, status} <- normalize_status(Keyword.get(opts, :status, :ok)),
         :ok <- validate_title(Keyword.get(opts, :title)),
         :ok <- validate_data(data),
         :ok <- validate_at(Keyword.get(opts, :at, DateTime.utc_now())) do
      {:ok,
       %__MODULE__{
         id: Keyword.get(opts, :id) || default_id(normalized_kind),
         at: Keyword.get(opts, :at, DateTime.utc_now()),
         session_id: Keyword.get(opts, :session_id),
         agent: agent,
         kind: normalized_kind,
         phase: Keyword.get(opts, :phase),
         status: status,
         title: Keyword.fetch!(opts, :title),
         detail: Keyword.get(opts, :detail),
         data: sanitize_data(data),
         raw: Keyword.get(opts, :raw)
       }}
    end
  end

  @spec new!(kind(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, event} -> event
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_runtime_message(term(), keyword()) :: [t()]
  def from_runtime_message(message, opts \\ [])

  def from_runtime_message(
        {:runic_ai_runtime, session_id, :trace_event, %TraceEvent{} = event},
        opts
      ) do
    [from_trace_event(event, Keyword.put(opts, :session_id, session_id))]
  end

  def from_runtime_message({:runic_ai_runtime, session_id, :output, output}, opts) do
    from_output(output, Keyword.put(opts, :session_id, session_id))
  end

  def from_runtime_message({:runic_ai_runtime, session_id, :snapshot, %Session{} = session}, opts) do
    [from_snapshot(session, Keyword.put(opts, :session_id, session_id))]
  end

  def from_runtime_message(_message, _opts), do: []

  @spec from_trace_event(TraceEvent.t(), keyword()) :: t()
  def from_trace_event(%TraceEvent{} = event, opts \\ []) do
    {kind, phase, title, detail} = trace_shape(event)

    new!(kind,
      id: event.id || default_id(kind),
      at: event.observed_at || DateTime.utc_now(),
      session_id: Keyword.get(opts, :session_id) || field(event.metadata, :session_id),
      agent: Keyword.get(opts, :agent, :standard),
      phase: phase,
      status: trace_status(event),
      title: title,
      detail: detail,
      data: %{
        trace_kind: event.kind,
        trace_id: event.trace_id,
        sequence: event.sequence,
        agent_id: event.agent_id,
        component: event.component,
        recipe: event.recipe,
        metadata: event.metadata,
        measurements: event.measurements,
        output: event.output
      },
      raw: event
    )
  end

  @spec from_output(term(), keyword()) :: [t()]
  def from_output(output, opts \\ []) do
    cond do
      match?(%ReviewRequest{}, review_request(output)) ->
        [from_review_request(review_request(output), opts)]

      match?(%Wait{}, wait(output)) ->
        [from_wait(wait(output), opts)]

      is_binary(reply_text(output)) ->
        [
          new!(:message,
            session_id: Keyword.get(opts, :session_id),
            agent: Keyword.get(opts, :agent, :standard),
            phase: :assistant,
            status: :ok,
            title: "Assistant response",
            detail: reply_text(output),
            data: %{reply_text: reply_text(output)},
            raw: output
          )
        ]

      true ->
        [
          new!(:summary,
            session_id: Keyword.get(opts, :session_id),
            agent: Keyword.get(opts, :agent, :standard),
            phase: :output,
            status: output_status(output),
            title: "Runtime output",
            detail: preview(output),
            data: %{output: output},
            raw: output
          )
        ]
    end
  end

  @spec from_snapshot(Session.t(), keyword()) :: t()
  def from_snapshot(%Session{} = session, opts \\ []) do
    new!(:status,
      session_id: Keyword.get(opts, :session_id) || session.id,
      agent: Keyword.get(opts, :agent, :standard),
      phase: :session,
      status: session_status(session.status),
      title: "Session #{session.status}",
      detail: "outputs=#{length(session.outputs)} events=#{length(session.trajectory.events)}",
      data: %{
        session_status: session.status,
        output_count: length(session.outputs),
        event_count: length(session.trajectory.events),
        measurements: session.measurements
      },
      raw: session
    )
  end

  @spec from_review_request(ReviewRequest.t(), keyword()) :: t()
  def from_review_request(%ReviewRequest{} = request, opts \\ []) do
    new!(:hitl,
      session_id: Keyword.get(opts, :session_id),
      agent: Keyword.get(opts, :agent, :standard),
      phase: :review,
      status: :review,
      title: "Review required: #{request.kind}",
      detail: review_detail(request),
      data: %{
        kind: request.kind,
        checkpoint: request.checkpoint,
        resume_key: request.resume_key,
        options: request.options,
        details: request.details,
        metadata: request.metadata
      },
      raw: request
    )
  end

  @spec from_wait(Wait.t(), keyword()) :: t()
  def from_wait(%Wait{} = wait, opts \\ []) do
    new!(:hitl,
      session_id: Keyword.get(opts, :session_id),
      agent: Keyword.get(opts, :agent, :standard),
      phase: :wait,
      status: :waiting,
      title: "Waiting: #{wait.kind}",
      detail: preview(wait.payload),
      data: %{
        kind: wait.kind,
        resume_key: wait.resume_key,
        until: wait.until,
        payload: wait.payload,
        metadata: wait.metadata
      },
      raw: wait
    )
  end

  @spec from_rlm_stage(term(), keyword()) :: t()
  def from_rlm_stage(stage, opts \\ []) do
    stage_name = field(stage, :stage) || field(stage, :phase) || :stage
    status = normalize_source_status(field(stage, :status) || :running)
    data = field(stage, :data) || stage
    agent = Keyword.get(opts, :agent, :rlm)

    new!(rlm_kind(stage_name),
      id: field(stage, :id) || default_id(:rlm_plan),
      at: field(stage, :at) || DateTime.utc_now(),
      session_id: Keyword.get(opts, :session_id) || field(stage, :run_id),
      agent: agent,
      phase: normalize_phase(stage_name),
      status: status,
      title: rlm_stage_title(stage_name, status, rlm_label(agent)),
      detail: preview(data),
      data: %{stage: stage_name, status: status, data: data},
      raw: stage
    )
  end

  @spec from_rlm_result(map(), keyword()) :: [t()]
  def from_rlm_result(result, opts \\ []) when is_map(result) do
    []
    |> maybe_append(rlm_proposal_event(result, opts))
    |> maybe_append(rlm_validation_event(result, opts))
    |> maybe_append(rlm_compiled_event(result, opts))
    |> Kernel.++(rlm_episode_events(result, opts))
    |> maybe_append(rlm_repair_event(result, opts))
    |> maybe_append(rlm_final_output_event(result, opts))
    |> maybe_append(rlm_scorecard_event(result, opts))
    |> maybe_append(rlm_persistence_event(result, opts))
  end

  @spec artifact_outcome_from_error(Error.t() | map() | nil) :: map() | nil
  def artifact_outcome_from_error(%Error{} = error) do
    artifact_outcome_from_error(Map.from_struct(error))
  end

  def artifact_outcome_from_error(error) when is_map(error) do
    normalize_artifact_outcome(field(error, :artifact_outcome)) ||
      error |> field(:details) |> artifact_outcome_from_details() ||
      error |> field(:metadata) |> artifact_outcome_from_details()
  end

  def artifact_outcome_from_error(_error), do: nil

  @spec to_json_map(t(), keyword()) :: map()
  def to_json_map(%__MODULE__{} = event, opts \\ []) do
    include_raw? = Keyword.get(opts, :include_raw?, false)

    %{
      id: event.id,
      at: DateTime.to_iso8601(event.at),
      session_id: event.session_id,
      agent: event.agent,
      kind: event.kind,
      phase: event.phase,
      status: event.status,
      title: event.title,
      detail: event.detail,
      data: json_safe(event.data)
    }
    |> maybe_put_raw(event.raw, include_raw?)
  end

  @spec json_safe(term()) :: term()
  def json_safe(value), do: json_safe(value, 0)

  defp trace_shape(%TraceEvent{kind: :turn_started}) do
    {:status, :turn, "Turn started", nil}
  end

  defp trace_shape(%TraceEvent{kind: :llm_request}) do
    {:status, :thinking, "LLM request", nil}
  end

  defp trace_shape(%TraceEvent{kind: :llm_result} = event) do
    {:status, :thinking, "LLM result", usage_detail(event.measurements)}
  end

  defp trace_shape(%TraceEvent{kind: :coding_tool_visibility} = event) do
    tools =
      event.output
      |> field(:visible_tools)
      |> case do
        tools when is_list(tools) -> Enum.join(tools, ", ")
        _other -> nil
      end

    {:tool, :visible_tools, "Visible tools", tools}
  end

  defp trace_shape(%TraceEvent{kind: :coding_tool_call} = event) do
    tool_name = field(event.metadata, :tool_name) || field(event.output, :name) || "tool"
    {:tool, :call, "Tool call: #{tool_name}", preview(event.output)}
  end

  defp trace_shape(%TraceEvent{kind: :coding_tool_observation} = event) do
    tool_name = field(event.metadata, :tool_name) || "tool"
    {:tool, :observation, "Tool observation: #{tool_name}", preview(event.output)}
  end

  defp trace_shape(%TraceEvent{kind: :coding_verification_observation} = event) do
    tool_name = field(event.metadata, :tool_name) || field(event.output, :tool) || "verification"
    status = field(event.output, :status)

    {:verification, :observation, "Verification: #{tool_name}",
     status_detail(status, event.output)}
  end

  defp trace_shape(%TraceEvent{kind: :coding_repair_attempt} = event) do
    iteration = field(event.output, :iteration) || field(event.metadata, :iteration)
    {:repair, :attempt, "Repair attempt #{iteration || "recorded"}", preview(event.output)}
  end

  defp trace_shape(%TraceEvent{kind: :review_requested} = event) do
    {:hitl, :review, "Review required", preview(event.output)}
  end

  defp trace_shape(%TraceEvent{kind: :wait_registered} = event) do
    {:hitl, :wait, "Wait registered", preview(event.output)}
  end

  defp trace_shape(%TraceEvent{kind: :workflow_quiesced} = event) do
    {:status, :workflow, "Workflow quiesced", usage_detail(event.measurements)}
  end

  defp trace_shape(%TraceEvent{kind: :turn_completed} = event) do
    {:status, :turn, "Turn completed", preview(event.output)}
  end

  defp trace_shape(%TraceEvent{kind: kind} = event) do
    event_kind = if kind == :error, do: :error, else: :status
    {event_kind, kind, humanize(kind), preview(event.output)}
  end

  defp rlm_proposal_event(result, opts) do
    case field(result, :proposal) do
      nil ->
        nil

      proposal ->
        agent = Keyword.get(opts, :agent, :rlm)

        new!(:rlm_plan,
          session_id: Keyword.get(opts, :session_id) || field(proposal, :id),
          agent: agent,
          phase: :proposed,
          status: :ok,
          title: "#{rlm_label(agent)} proposal: #{field(proposal, :id) || "proposal"}",
          detail:
            "#{length(field(proposal, :nodes) || field(proposal, :components) || [])} nodes",
          data: %{proposal: summarize_proposal(proposal)},
          raw: proposal
        )
    end
  end

  defp rlm_validation_event(result, opts) do
    case field(result, :validation_report) do
      nil ->
        nil

      report ->
        agent = Keyword.get(opts, :agent, :rlm)
        status = if field(report, :status) in [:accepted, "accepted"], do: :ok, else: :error

        new!(:rlm_plan,
          session_id: Keyword.get(opts, :session_id),
          agent: agent,
          phase: :validated,
          status: status,
          title: "#{rlm_label(agent)} validation #{field(report, :status)}",
          detail: validation_detail(report),
          data: %{validation_report: report},
          raw: report
        )
    end
  end

  defp rlm_compiled_event(result, opts) do
    case field(result, :compiled) do
      nil ->
        nil

      compiled ->
        agent = Keyword.get(opts, :agent, :rlm)

        new!(:rlm_plan,
          session_id: Keyword.get(opts, :session_id),
          agent: agent,
          phase: :compiled,
          status: :ok,
          title: "#{rlm_label(agent)} workflow compiled",
          detail: preview(compiled),
          data: %{compiled: compiled},
          raw: compiled
        )
    end
  end

  defp rlm_episode_events(result, opts) do
    result
    |> episodes()
    |> Enum.with_index(1)
    |> Enum.map(fn {episode, index} ->
      agent = Keyword.get(opts, :agent, :rlm)

      new!(:rlm_node,
        session_id: Keyword.get(opts, :session_id),
        agent: agent,
        phase: :episode,
        status: normalize_source_status(field(episode, :status) || :ok),
        title:
          "#{rlm_label(agent)} episode #{field(episode, :node_id) || field(episode, :id) || index}",
        detail: preview(episode),
        data: %{episode: episode, index: index},
        raw: episode
      )
    end)
  end

  defp rlm_repair_event(result, opts) do
    history = field(result, :repair_history) || field(result, :repair_attempts)

    if is_list(history) and history != [] do
      agent = Keyword.get(opts, :agent, :rlm)

      new!(:repair,
        session_id: Keyword.get(opts, :session_id),
        agent: agent,
        phase: :repair,
        status: normalize_source_status(field(result, :repair_status) || :ok),
        title: "#{rlm_label(agent)} repairs: #{length(history)}",
        detail: preview(List.last(history)),
        data: %{repair_status: field(result, :repair_status), repair_history: history},
        raw: history
      )
    end
  end

  defp rlm_final_output_event(result, opts) do
    agent = Keyword.get(opts, :agent, :rlm)

    if agent in [:rlm, :assistant] do
      result
      |> rlm_final_output_text()
      |> case do
        text when is_binary(text) ->
          text = String.trim(text)

          if text != "" do
            status = final_output_status(result)
            artifact_paths = artifact_paths(result)
            artifact_outcome = artifact_outcome(result, artifact_paths)

            new!(:message,
              session_id: Keyword.get(opts, :session_id),
              agent: agent,
              phase: :assistant,
              status: status,
              title: "#{rlm_label(agent)} final output",
              detail: preview(text),
              data:
                %{
                  run_id: Keyword.get(opts, :run_id) || Keyword.get(opts, :session_id),
                  role: "assistant",
                  message_kind: "workflow_output",
                  content: text,
                  output_text: text,
                  blocked?: status == :blocked,
                  blocking_reason: blocking_reason(result),
                  artifact_paths: artifact_paths
                }
                |> maybe_put(:artifact_outcome, artifact_outcome),
              raw: result
            )
          end

        _other ->
          nil
      end
    end
  end

  defp final_output_status(result) do
    case scorecard(result) do
      nil ->
        :ok

      scorecard ->
        if field(scorecard, :objective_status) in [:objective_incomplete, "objective_incomplete"] do
          :blocked
        else
          :ok
        end
    end
  end

  defp blocking_reason(result) do
    case scorecard(result) do
      nil ->
        nil

      scorecard ->
        scorecard
        |> field(:residual_risks)
        |> List.wrap()
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string/1)
        |> Enum.join("; ")
        |> case do
          "" -> nil
          reason -> reason
        end
    end
  end

  defp rlm_scorecard_event(result, opts) do
    case scorecard(result) do
      nil ->
        nil

      scorecard ->
        agent = Keyword.get(opts, :agent, :rlm)
        objective_status = field(scorecard, :objective_status)

        new!(:summary,
          session_id: Keyword.get(opts, :session_id),
          agent: agent,
          phase: :scorecard,
          status:
            if(objective_status in [:objective_satisfied, "objective_satisfied"],
              do: :ok,
              else: :blocked
            ),
          title: "#{rlm_label(agent)} objective #{objective_status}",
          detail: scorecard_detail(scorecard),
          data: %{scorecard: scorecard},
          raw: scorecard
        )
    end
  end

  defp rlm_persistence_event(result, opts) do
    case field(result, :persistence_ref) do
      nil ->
        nil

      ref ->
        agent = Keyword.get(opts, :agent, :rlm)

        new!(:summary,
          session_id: Keyword.get(opts, :session_id),
          agent: agent,
          phase: :persistence,
          status: :ok,
          title: "#{rlm_label(agent)} persisted",
          detail: to_string(ref),
          data: %{persistence_ref: ref},
          raw: ref
        )
    end
  end

  defp summarize_proposal(proposal) do
    edges = field(proposal, :edges) || []
    proposal_nodes = field(proposal, :nodes) || field(proposal, :components) || []

    nodes =
      proposal_nodes
      |> List.wrap()
      |> Enum.map(fn node ->
        id = field(node, :id)

        %{
          id: id,
          kind: field(node, :kind) || field(node, :type),
          inputs: field(node, :inputs) || [],
          outputs: field(node, :outputs) || [],
          dependencies: dependencies_for(id, edges),
          params: field(node, :params) || %{},
          policy: field(node, :policy) || %{}
        }
      end)

    %{
      id: field(proposal, :id),
      objective: field(proposal, :objective),
      nodes: nodes,
      edges: edges,
      stop_conditions: field(proposal, :stop_conditions) || []
    }
  end

  defp dependencies_for(nil, _edges), do: []

  defp dependencies_for(id, edges) do
    edges
    |> Enum.filter(&(field(&1, :to) == id))
    |> Enum.map(&field(&1, :from))
    |> Enum.reject(&is_nil/1)
  end

  defp episodes(result) do
    cond do
      is_list(field(result, :episodes)) ->
        field(result, :episodes)

      is_map(field(result, :context)) and is_list(field(field(result, :context), :episodes)) ->
        field(field(result, :context), :episodes)

      true ->
        []
    end
  end

  defp scorecard(result) do
    cond do
      not is_nil(field(result, :scorecard)) ->
        field(result, :scorecard)

      not is_nil(field(result, :objective_scorecard)) ->
        field(result, :objective_scorecard)

      is_map(field(result, :context)) ->
        field(field(result, :context), :scorecards)
        |> case do
          scorecards when is_list(scorecards) -> List.last(scorecards)
          _other -> nil
        end

      true ->
        nil
    end
  end

  defp rlm_final_output_text(result) do
    [
      text_field(result, :output_text),
      text_field(result, :final_answer),
      text_field(result, :reply_text),
      text_field(result, :content),
      text_candidate(field(result, :output)),
      episode_output_text(result),
      text_candidate(field(result, :repair_history)),
      text_candidate(field(result, :repair_attempts)),
      text_candidate(field(result, :artifacts))
    ]
    |> Enum.find(&present_text?/1)
  end

  defp episode_output_text(result) do
    result
    |> episodes()
    |> Enum.reverse()
    |> Enum.find_value(fn episode ->
      text_candidate(field(episode, :outcome)) ||
        text_candidate(field(episode, :output)) ||
        text_candidate(field(episode, :artifacts))
    end)
  end

  defp text_field(map, key) do
    case field(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp text_candidate(nil), do: nil
  defp text_candidate(value) when is_binary(value), do: value

  defp text_candidate(values) when is_list(values) do
    values
    |> Enum.reverse()
    |> Enum.find_value(&text_candidate/1)
  end

  defp text_candidate(%{} = value) do
    text_field(value, :output_text) ||
      text_field(value, :final_answer) ||
      text_field(value, :reply_text) ||
      text_field(value, :content) ||
      text_field(value, :text) ||
      text_field(value, :text_preview) ||
      text_candidate(field(value, :output)) ||
      text_candidate(field(value, :outcome)) ||
      text_candidate(field(value, :value)) ||
      structured_report_candidate(value)
  end

  defp text_candidate(_value), do: nil

  defp structured_report_candidate(%{} = value) do
    if structured_report_map?(value) do
      RunicAI.Coding.RLM.Reducers.reduce(:report, [value])
    end
  end

  defp structured_report_map?(value) do
    Enum.any?([:files, :entries, :matches, :path, :stdout, :stderr, :exit_status], fn key ->
      not is_nil(field(value, key))
    end)
  end

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp artifact_paths(result) do
    result
    |> field(:artifacts)
    |> List.wrap()
    |> Enum.map(fn artifact -> field(artifact, :path) || field(artifact, :absolute_path) end)
    |> Enum.filter(&present_text?/1)
    |> Enum.uniq()
  end

  defp artifact_outcome(result, paths) do
    explicit =
      normalize_artifact_outcome(field(result, :artifact_outcome)) ||
        result |> field(:metadata) |> artifact_outcome_from_details()

    cond do
      not is_nil(explicit) -> explicit
      paths == [] -> nil
      true -> %{status: "artifact_written", paths: paths}
    end
  end

  defp artifact_outcome_from_details(details) when is_map(details) do
    normalize_artifact_outcome(field(details, :artifact_outcome))
  end

  defp artifact_outcome_from_details(_details), do: nil

  defp normalize_artifact_outcome(nil), do: nil

  defp normalize_artifact_outcome(outcome) when is_map(outcome) do
    status = field(outcome, :status)
    reason = field(outcome, :reason)
    paths = outcome |> field(:paths) |> List.wrap() |> Enum.filter(&present_text?/1)

    suggested_paths =
      outcome |> field(:suggested_paths) |> List.wrap() |> Enum.filter(&present_text?/1)

    base =
      cond do
        status in [:artifact_written, "artifact_written"] ->
          %{status: "artifact_written"}

        status in [:artifact_not_written, "artifact_not_written", :not_written, "not_written"] ->
          %{status: "artifact_not_written"}

        present_text?(reason) ->
          %{status: "artifact_not_written"}

        true ->
          nil
      end

    if is_nil(base) do
      nil
    else
      base
      |> maybe_put(:reason, normalize_outcome_reason(reason))
      |> maybe_put(:path, field(outcome, :path))
      |> maybe_put(:paths, non_empty(paths))
      |> maybe_put(:suggested_paths, non_empty(suggested_paths))
      |> maybe_put(:decision_status, field(outcome, :decision_status))
      |> maybe_put(:policy, field(outcome, :policy))
    end
  end

  defp normalize_artifact_outcome(_outcome), do: nil

  defp normalize_outcome_reason(nil), do: nil
  defp normalize_outcome_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_outcome_reason(reason) when is_binary(reason), do: reason
  defp normalize_outcome_reason(reason), do: inspect(reason)

  defp non_empty([]), do: nil
  defp non_empty(values), do: values

  defp trace_status(%TraceEvent{kind: :review_requested}), do: :review
  defp trace_status(%TraceEvent{kind: :wait_registered}), do: :waiting
  defp trace_status(%TraceEvent{kind: :error}), do: :error
  defp trace_status(%TraceEvent{status: status}), do: normalize_source_status(status)

  defp output_status(output) do
    cond do
      match?(%ReviewRequest{}, review_request(output)) -> :review
      match?(%Wait{}, wait(output)) -> :waiting
      true -> :ok
    end
  end

  defp session_status(:review), do: :review
  defp session_status(:waiting), do: :waiting
  defp session_status(:queued), do: :pending
  defp session_status(:running), do: :running
  defp session_status(:error), do: :error
  defp session_status(_status), do: :ok

  defp normalize_source_status(nil), do: :ok
  defp normalize_source_status(status) when status in @statuses, do: status

  defp normalize_source_status(status)
       when status in [:pass, :passed, :accepted, :completed, :idle],
       do: :ok

  defp normalize_source_status(status) when status in [:fail, :failed, :rejected, :timeout],
    do: :error

  defp normalize_source_status(status) when status in [:wait, :waiting], do: :waiting
  defp normalize_source_status(status) when status in [:review, :review_required], do: :review

  defp normalize_source_status(status) when status in [:blocked, :objective_incomplete],
    do: :blocked

  defp normalize_source_status(status) when status in [:running, :queued], do: :running

  defp normalize_source_status(status) when is_binary(status) do
    case status do
      "ok" -> :ok
      "pass" -> :ok
      "passed" -> :ok
      "accepted" -> :ok
      "completed" -> :ok
      "idle" -> :ok
      "fail" -> :error
      "failed" -> :error
      "error" -> :error
      "rejected" -> :error
      "timeout" -> :error
      "wait" -> :waiting
      "waiting" -> :waiting
      "review" -> :review
      "review_required" -> :review
      "blocked" -> :blocked
      "objective_incomplete" -> :blocked
      "running" -> :running
      "queued" -> :running
      _other -> :ok
    end
  end

  defp normalize_source_status(_status), do: :ok

  defp normalize_kind(kind) when kind in @kinds, do: {:ok, kind}

  defp normalize_kind(kind) do
    {:error,
     Error.validation("invalid terminal event kind",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @kinds}
     )}
  end

  defp normalize_agent(agent) when agent in @agents, do: {:ok, agent}

  defp normalize_agent(agent) do
    {:error,
     Error.validation("invalid terminal event agent",
       source: __MODULE__,
       details: %{agent: agent, valid_agents: @agents}
     )}
  end

  defp normalize_status(status) when status in @statuses, do: {:ok, status}

  defp normalize_status(status) do
    {:error,
     Error.validation("invalid terminal event status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @statuses}
     )}
  end

  defp validate_title(title) when is_binary(title) and title != "", do: :ok

  defp validate_title(title) do
    {:error,
     Error.validation("terminal event title must be a non-empty string",
       source: __MODULE__,
       details: %{title: title}
     )}
  end

  defp validate_data(data) when is_map(data), do: :ok

  defp validate_data(data) do
    {:error,
     Error.validation("terminal event data must be a map",
       source: __MODULE__,
       details: %{data: data}
     )}
  end

  defp validate_at(%DateTime{}), do: :ok

  defp validate_at(at) do
    {:error,
     Error.validation("terminal event timestamp must be a DateTime",
       source: __MODULE__,
       details: %{at: at}
     )}
  end

  defp sanitize_data(data), do: json_safe(data)

  defp json_safe(_value, depth) when depth > 8, do: "[depth limit]"
  defp json_safe(nil, _depth), do: nil
  defp json_safe(value, _depth) when is_boolean(value), do: value
  defp json_safe(value, _depth) when is_integer(value) or is_float(value), do: value
  defp json_safe(value, _depth) when is_binary(value), do: safe_binary(value)
  defp json_safe(%DateTime{} = value, _depth), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value, _depth), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Date{} = value, _depth), do: Date.to_iso8601(value)
  defp json_safe(%Time{} = value, _depth), do: Time.to_iso8601(value)
  defp json_safe(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value, depth) when is_list(value) do
    value
    |> Enum.take(100)
    |> Enum.map(&json_safe(&1, depth + 1))
  end

  defp json_safe(value, depth) when is_map(value) do
    value
    |> struct_map()
    |> Enum.take(100)
    |> Map.new(fn {key, map_value} -> {json_key(key), json_safe(map_value, depth + 1)} end)
  end

  defp json_safe(value, _depth), do: inspect(value, limit: 20, printable_limit: 512)

  defp safe_binary(value) do
    cond do
      not String.valid?(value) ->
        Base.encode64(value)

      String.length(value) > 8_192 ->
        String.slice(value, 0, 8_192) <> "\n[truncated]"

      true ->
        value
    end
  end

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)

  defp struct_map(value) when is_map(value) do
    if Map.has_key?(value, :__struct__) do
      value
      |> Map.from_struct()
      |> Map.put(:__struct__, inspect(value.__struct__))
    else
      value
    end
  end

  defp maybe_put_raw(map, raw, true), do: Map.put(map, :raw, json_safe(raw))
  defp maybe_put_raw(map, _raw, false), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_append(events, nil), do: events
  defp maybe_append(events, event), do: events ++ [event]

  defp rlm_kind(stage)
       when stage in [
              :episode_completed,
              :node_started,
              :node_completed,
              :node_failed,
              :execution_started,
              :execution_completed
            ],
       do: :rlm_node

  defp rlm_kind(stage)
       when stage in [:repair_attempt_started, :repair_attempt_completed, :repair_completed],
       do: :repair

  defp rlm_kind(stage) when stage in [:review_requested, :review_completed], do: :hitl

  defp rlm_kind(stage) when stage in [:progress_gate_completed, :scorecard, :scorecard_completed],
    do: :summary

  defp rlm_kind(_stage), do: :rlm_plan

  defp normalize_phase(value) when is_atom(value), do: value
  defp normalize_phase(value) when is_binary(value), do: String.replace(value, "-", "_")
  defp normalize_phase(_value), do: :stage

  defp rlm_label(:assistant), do: "Assistant RLM"
  defp rlm_label(_agent), do: "RLM"

  defp rlm_stage_title(stage, status, label), do: "#{label} #{humanize(stage)} #{status}"

  defp validation_detail(report) do
    errors = report |> field(:errors) |> List.wrap() |> length()
    warnings = report |> field(:warnings) |> List.wrap() |> length()
    "errors=#{errors} warnings=#{warnings}"
  end

  defp scorecard_detail(scorecard) do
    risks = field(scorecard, :residual_risks) || []
    changed = field(scorecard, :changed_files) || []
    "changed=#{length(changed)} risks=#{length(risks)}"
  end

  defp review_detail(%ReviewRequest{} = request) do
    request.details
    |> Map.get(:reason, Map.get(request.details, "reason", request.checkpoint || request.kind))
    |> preview()
  end

  defp status_detail(nil, output), do: preview(output)
  defp status_detail(status, output), do: "#{status}: #{preview(output)}"

  defp usage_detail(measurements) when is_map(measurements) do
    case Map.take(measurements, [:input_tokens, :output_tokens, :total_tokens, :elapsed_ms]) do
      empty when map_size(empty) == 0 -> nil
      usage -> preview(usage)
    end
  end

  defp usage_detail(_measurements), do: nil

  defp preview(nil), do: nil
  defp preview(value) when is_binary(value), do: truncate(value)

  defp preview(value) do
    value
    |> json_safe()
    |> inspect(limit: 20, printable_limit: 512)
    |> truncate()
  end

  defp truncate(nil), do: nil

  defp truncate(value) when is_binary(value) do
    if String.length(value) > 512 do
      String.slice(value, 0, 512) <> "..."
    else
      value
    end
  end

  defp review_request(output) do
    field(output, :latest_review_request) || field(output, :review_request)
  end

  defp wait(output), do: field(output, :latest_wait) || field(output, :wait)

  defp reply_text(output) do
    field(output, :latest_reply_text) || field(output, :reply_text)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.capitalize()

  defp humanize(value), do: value |> inspect() |> humanize()

  defp default_id(kind), do: Ids.unique("terminal:#{kind}")
end
