defmodule RunicAI.Event do
  @moduledoc """
  Shared runtime/client event contract.

  This module is the presentation-neutral event boundary for RunicAI clients.
  CLI, TUI, WebUI, persistence, and other clients can consume this common shape
  directly or translate it into their own presentation events. Terminal-specific
  event modules are adapters around this contract, not the owner of the shared
  vocabulary.
  """

  alias RunicAI.Error
  alias RunicAI.Ids

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
    :run_id,
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

  @type workflow_effect ::
          :plan | :progress | :analysis | :tool_calls | :final | :error

  @type t :: %__MODULE__{
          id: String.t(),
          at: DateTime.t(),
          session_id: String.t() | nil,
          run_id: String.t() | nil,
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
      run_id = Keyword.get(opts, :run_id) || field(data, :run_id)

      {:ok,
       %__MODULE__{
         id: Keyword.get(opts, :id) || default_id(normalized_kind),
         at: Keyword.get(opts, :at, DateTime.utc_now()),
         session_id: Keyword.get(opts, :session_id),
         run_id: run_id,
         agent: agent,
         kind: normalized_kind,
         phase: normalize_phase(Keyword.get(opts, :phase)),
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

  @spec from_stream_stage(term(), keyword()) :: t()
  def from_stream_stage(stage, opts \\ [])

  def from_stream_stage(%__MODULE__{} = event, _opts), do: event

  def from_stream_stage(stage, opts) do
    stage_name = field(stage, :stage) || field(stage, :phase) || :llm_stream_chunk
    status = normalize_source_status(field(stage, :status) || stream_stage_status(stage_name))
    data = field(stage, :data) || stage
    agent = Keyword.get(opts, :agent) || stream_agent(data) || :assistant
    run_id = Keyword.get(opts, :run_id) || field(stage, :run_id) || field(data, :run_id)
    session_id = Keyword.get(opts, :session_id) || field(data, :session_id) || run_id

    new!(stream_stage_kind(stage_name),
      id: field(stage, :id) || default_id(stream_stage_kind(stage_name)),
      at: field(stage, :at) || DateTime.utc_now(),
      session_id: session_id,
      run_id: run_id,
      agent: agent,
      phase: stream_stage_phase(stage_name),
      status: status,
      title: stream_stage_title(stage_name, status),
      detail: stream_stage_detail(data),
      data: Map.put_new(data || %{}, :run_id, run_id),
      raw: stage
    )
  end

  @spec from_rlm_stage(term(), keyword()) :: t()
  def from_rlm_stage(stage, opts \\ [])

  def from_rlm_stage(%__MODULE__{} = event, _opts), do: event

  def from_rlm_stage(%{stage: stage_name} = stage, opts)
      when stage_name in [
             :llm_stream_chunk,
             "llm_stream_chunk",
             :llm_stream_completed,
             "llm_stream_completed",
             :llm_stream_failed,
             "llm_stream_failed"
           ] do
    from_stream_stage(stage, opts)
  end

  def from_rlm_stage(%{"stage" => stage_name} = stage, opts)
      when stage_name in [
             :llm_stream_chunk,
             "llm_stream_chunk",
             :llm_stream_completed,
             "llm_stream_completed",
             :llm_stream_failed,
             "llm_stream_failed"
           ] do
    from_stream_stage(stage, opts)
  end

  def from_rlm_stage(stage, opts) do
    stage_name = field(stage, :stage) || field(stage, :phase) || :stage
    status = normalize_source_status(field(stage, :status) || :running)
    data = field(stage, :data) || stage
    agent = Keyword.get(opts, :agent, :rlm)
    run_id = Keyword.get(opts, :run_id) || field(stage, :run_id) || field(data, :run_id)
    session_id = Keyword.get(opts, :session_id) || field(data, :session_id) || run_id

    new!(rlm_kind(stage_name),
      id: field(stage, :id) || default_id(rlm_kind(stage_name)),
      at: field(stage, :at) || DateTime.utc_now(),
      session_id: session_id,
      run_id: run_id,
      agent: agent,
      phase: normalize_phase(stage_name),
      status: status,
      title: rlm_stage_title(stage_name, status, rlm_label(agent)),
      detail: preview(data),
      data: %{stage: stage_name, status: status, data: data},
      raw: stage
    )
  end

  @spec workflow_effect(workflow_effect(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def workflow_effect(effect, opts \\ []) when is_list(opts) do
    data = Keyword.get(opts, :data, %{})
    run_id = Keyword.get(opts, :run_id) || field(data, :run_id)
    session_id = Keyword.get(opts, :session_id) || field(data, :session_id) || run_id
    presentation_group_id = Keyword.get(opts, :presentation_group_id) || run_id || session_id
    source_step = Keyword.get(opts, :source_step) || effect
    workflow_node = Keyword.get(opts, :workflow_node) || field(data, :workflow_node)
    message_kind = Keyword.get(opts, :message_kind) || effect_message_kind(effect)

    data =
      data
      |> put_new_data(:message_kind, message_kind)
      |> put_new_data(:presentation_group_id, presentation_group_id)
      |> put_new_data(:source_step, source_step)
      |> put_new_data(:transient, effect_transient?(effect))
      |> maybe_put_data(:workflow_node, workflow_node)
      |> maybe_put_data(:content, Keyword.get(opts, :content))
      |> maybe_put_data(:output_text, Keyword.get(opts, :content))

    new(effect_kind(effect),
      id: Keyword.get(opts, :id),
      at: Keyword.get(opts, :at, DateTime.utc_now()),
      session_id: session_id,
      run_id: run_id,
      agent: Keyword.get(opts, :agent, :assistant),
      phase: Keyword.get(opts, :phase, effect_phase(effect)),
      status: Keyword.get(opts, :status, effect_status(effect)),
      title: Keyword.get(opts, :title, effect_title(effect)),
      detail: Keyword.get(opts, :detail) || Keyword.get(opts, :content),
      data: data,
      raw: Keyword.get(opts, :raw)
    )
  end

  @spec workflow_effect!(workflow_effect(), keyword()) :: t()
  def workflow_effect!(effect, opts \\ []) do
    case workflow_effect(effect, opts) do
      {:ok, event} -> event
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec to_json_map(t(), keyword()) :: map()
  def to_json_map(%__MODULE__{} = event, opts \\ []) do
    include_raw? = Keyword.get(opts, :include_raw?, false)

    %{
      id: event.id,
      at: DateTime.to_iso8601(event.at),
      session_id: event.session_id,
      run_id: event.run_id,
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

  defp normalize_kind(kind) when kind in @kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    kind
    |> String.to_existing_atom()
    |> normalize_kind()
  rescue
    ArgumentError ->
      {:error, Error.validation("unsupported event kind: #{inspect(kind)}", source: __MODULE__)}
  end

  defp normalize_kind(kind) do
    {:error, Error.validation("unsupported event kind: #{inspect(kind)}", source: __MODULE__)}
  end

  defp normalize_agent(agent) when agent in @agents, do: {:ok, agent}

  defp normalize_agent(agent) when is_binary(agent) do
    agent
    |> String.to_existing_atom()
    |> normalize_agent()
  rescue
    ArgumentError ->
      {:error, Error.validation("unsupported event agent: #{inspect(agent)}", source: __MODULE__)}
  end

  defp normalize_agent(agent) do
    {:error, Error.validation("unsupported event agent: #{inspect(agent)}", source: __MODULE__)}
  end

  defp normalize_status(status) when status in @statuses, do: {:ok, status}

  defp normalize_status(status) when is_binary(status) do
    status
    |> String.to_existing_atom()
    |> normalize_status()
  rescue
    ArgumentError ->
      {:error,
       Error.validation("unsupported event status: #{inspect(status)}", source: __MODULE__)}
  end

  defp normalize_status(status) do
    {:error, Error.validation("unsupported event status: #{inspect(status)}", source: __MODULE__)}
  end

  defp normalize_source_status(value) do
    case normalize_status(value) do
      {:ok, status} -> status
      {:error, _error} -> :running
    end
  end

  defp validate_title(title) when is_binary(title) and byte_size(title) > 0, do: :ok

  defp validate_title(title) do
    {:error,
     Error.validation("event title is required", source: __MODULE__, details: %{title: title})}
  end

  defp validate_data(data) when is_map(data), do: :ok

  defp validate_data(data) do
    {:error,
     Error.validation("event data must be a map", source: __MODULE__, details: %{data: data})}
  end

  defp validate_at(%DateTime{}), do: :ok

  defp validate_at(at) do
    {:error,
     Error.validation("event timestamp must be a DateTime",
       source: __MODULE__,
       details: %{at: at}
     )}
  end

  defp default_id(kind), do: Ids.unique("event:#{kind}")

  defp stream_stage_kind(stage)
       when stage in [:llm_stream_chunk, "llm_stream_chunk"],
       do: :chunk

  defp stream_stage_kind(_stage), do: :message

  defp stream_stage_phase(stage)
       when stage in [:llm_stream_chunk, "llm_stream_chunk"],
       do: :assistant_chunk

  defp stream_stage_phase(stage)
       when stage in [:llm_stream_failed, "llm_stream_failed"],
       do: :assistant_stream_failed

  defp stream_stage_phase(_stage), do: :assistant

  defp stream_stage_status(stage)
       when stage in [:llm_stream_chunk, "llm_stream_chunk"],
       do: :running

  defp stream_stage_status(stage)
       when stage in [:llm_stream_failed, "llm_stream_failed"],
       do: :error

  defp stream_stage_status(_stage), do: :ok

  defp stream_stage_title(stage, _status)
       when stage in [:llm_stream_chunk, "llm_stream_chunk"],
       do: "Assistant stream chunk"

  defp stream_stage_title(stage, _status)
       when stage in [:llm_stream_failed, "llm_stream_failed"],
       do: "Assistant stream failed"

  defp stream_stage_title(_stage, _status), do: "Assistant stream complete"

  defp stream_stage_detail(data),
    do: field(data, :chunk) || field(data, :content) || field(data, :text)

  defp stream_agent(data) do
    case field(data, :agent) do
      agent when agent in @agents -> agent
      "standard" -> :standard
      "assistant" -> :assistant
      "rlm" -> :rlm
      _other -> nil
    end
  end

  defp rlm_kind(stage)
       when stage in [
              :episode_completed,
              :node_started,
              :node_budget_selected,
              :node_completed,
              :node_failed,
              :child_agent_started,
              :child_agent_progress,
              :child_agent_event,
              :child_agent_completed,
              :child_budget_selected,
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

  defp rlm_stage_title(stage, status, label), do: "#{label} #{humanize(stage)} #{status}"
  defp rlm_label(:assistant), do: "Assistant RLM"
  defp rlm_label(_agent), do: "RLM"

  defp effect_kind(:plan), do: :rlm_plan
  defp effect_kind(:progress), do: :rlm_node
  defp effect_kind(:analysis), do: :message
  defp effect_kind(:tool_calls), do: :tool
  defp effect_kind(:final), do: :message
  defp effect_kind(:error), do: :error

  defp effect_phase(:tool_calls), do: :tool_calls
  defp effect_phase(effect), do: effect

  defp effect_status(:error), do: :error
  defp effect_status(_effect), do: :ok

  defp effect_message_kind(:tool_calls), do: "tool_calls"
  defp effect_message_kind(effect), do: Atom.to_string(effect)

  defp effect_transient?(:final), do: false
  defp effect_transient?(:error), do: false
  defp effect_transient?(_effect), do: true

  defp effect_title(:plan), do: "Plan update"
  defp effect_title(:progress), do: "Workflow progress"
  defp effect_title(:analysis), do: "Analysis update"
  defp effect_title(:tool_calls), do: "Tool activity"
  defp effect_title(:final), do: "Assistant response"
  defp effect_title(:error), do: "Workflow error"

  defp normalize_phase(nil), do: nil
  defp normalize_phase(value) when is_atom(value), do: value
  defp normalize_phase(value) when is_binary(value), do: String.replace(value, "-", "_")
  defp normalize_phase(_value), do: nil

  defp preview(value) when is_binary(value) do
    if String.length(value) > 220, do: String.slice(value, 0, 220) <> "...", else: value
  end

  defp preview(value), do: inspect(value, limit: 12, printable_limit: 220)

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
      byte_size(value) <= 4_000 -> value
      true -> binary_part(value, 0, 4_000) <> "..."
    end
  end

  defp struct_map(%_struct{} = value), do: Map.from_struct(value)
  defp struct_map(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key, limit: 20, printable_limit: 512)

  defp maybe_put_raw(map, _raw, false), do: map
  defp maybe_put_raw(map, raw, true), do: Map.put(map, :raw, json_safe(raw))

  defp put_new_data(data, _key, nil), do: data
  defp put_new_data(data, key, value), do: Map.put_new(data, key, value)

  defp maybe_put_data(data, _key, nil), do: data
  defp maybe_put_data(data, key, value), do: Map.put(data, key, value)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize(value), do: inspect(value)
end
