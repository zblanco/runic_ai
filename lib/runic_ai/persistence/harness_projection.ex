defmodule RunicAI.Persistence.HarnessProjection do
  @moduledoc """
  Projects normalized terminal events into first-class RunicAI read models.

  Terminal events stay the durable presentation-neutral event stream. This
  projection keeps the operational and eval-oriented tables queryable without
  requiring callers to replay opaque event payloads for common inspections.
  """

  import Ecto.Query

  alias RunicAI.Coding.Patch
  alias RunicAI.Persistence.JSON
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.Schemas.AgentConversation
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.AgentMessageChunk
  alias RunicAI.Persistence.Schemas.AgentSession
  alias RunicAI.Persistence.Schemas.RepairAttempt
  alias RunicAI.Persistence.Schemas.ReviewRequest
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.RunnableEvent
  alias RunicAI.Persistence.Schemas.Scorecard
  alias RunicAI.Persistence.Schemas.SubagentRun
  alias RunicAI.Persistence.Schemas.TerminalEvent
  alias RunicAI.Persistence.Schemas.ToolCall
  alias RunicAI.Persistence.Schemas.WorkflowRun

  @spec project_terminal_event(Store.t(), TerminalEvent.t()) :: :ok | {:error, term()}
  def project_terminal_event(%Store{} = store, %TerminalEvent{} = event) do
    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        store.repo.transaction(fn ->
          project_terminal_event!(store, event)
        end)
      end)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
      :ok -> :ok
    end
  rescue
    exception -> {:error, exception}
  end

  defp project_terminal_event!(%Store{} = store, %TerminalEvent{} = event) do
    ensure_session!(store, event)
    ensure_workflow_run!(store, event)
    project_event_kind!(store, event)
    :ok
  end

  defp ensure_session!(_store, %TerminalEvent{session_id: nil}), do: :ok

  defp ensure_session!(%Store{} = store, %TerminalEvent{} = event) do
    attrs = %{
      id: event.session_id,
      agent_kind: event.agent,
      workspace_root: data_field(event, :cwd),
      objective: data_field(event, :objective),
      model: data_field(event, :model),
      status: session_status(event),
      started_at: event.at,
      completed_at: completed_at(event),
      failed_at: failed_at(event),
      metadata_json: %{
        last_event_id: event.id,
        last_event_kind: event.kind,
        last_event_phase: event.phase,
        last_event_title: event.title,
        run_id: event.run_id
      }
    }

    upsert_by_id!(store, AgentSession, event.session_id, attrs, [:metadata_json])
  end

  defp ensure_workflow_run!(_store, %TerminalEvent{run_id: nil}), do: :ok

  defp ensure_workflow_run!(%Store{} = store, %TerminalEvent{} = event) do
    attrs = %{
      id: event.run_id,
      workflow_key: event.run_id,
      workflow_name: workflow_name(event),
      workflow_id_blob: Term.to_blob(event.run_id),
      session_id: event.session_id,
      status: run_status(event),
      trigger: data_field(event, :trigger),
      metadata_json: workflow_metadata(event),
      last_event_sequence: event.sequence,
      started_at: event.at,
      completed_at: completed_at(event),
      failed_at: failed_at(event),
      last_checkpointed_at: nil,
      error_json: error_json(event)
    }

    attrs =
      case store.repo.get(WorkflowRun, event.run_id) do
        nil ->
          attrs

        %WorkflowRun{} = run ->
          %{
            attrs
            | workflow_key: run.workflow_key || attrs.workflow_key,
              workflow_name: run.workflow_name || attrs.workflow_name,
              workflow_id_blob: run.workflow_id_blob || attrs.workflow_id_blob,
              started_at: run.started_at || attrs.started_at
          }
      end

    upsert_by_id!(store, WorkflowRun, event.run_id, attrs, [:metadata_json, :error_json])
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "message"} = event) do
    conversation = ensure_conversation!(store, event)
    insert_message!(store, event, conversation.id, "assistant", event.phase || "message")
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "chunk"} = event) do
    conversation = ensure_conversation!(store, event)
    message = insert_message!(store, event, conversation.id, "assistant", "stream")

    attrs = %{
      message_id: message.id,
      sequence: event.sequence || 1,
      chunk_kind: event.phase || "chunk",
      content: event.detail,
      payload_json: event.data_json,
      created_at: event.at
    }

    %AgentMessageChunk{}
    |> AgentMessageChunk.changeset(attrs)
    |> store.repo.insert!(
      on_conflict: {:replace, [:chunk_kind, :content, :payload_json, :created_at]},
      conflict_target: [:message_id, :sequence]
    )
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "summary"} = event) do
    maybe_insert_scorecard!(store, event)
    maybe_insert_artifacts!(store, event)
    maybe_insert_graph_summary!(store, event)

    if final_summary?(event) do
      conversation = ensure_conversation!(store, event)
      insert_message!(store, event, conversation.id, "assistant", "summary")
    end

    :ok
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "tool"} = event) do
    insert_tool_call!(store, event)
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "hitl"} = event) do
    insert_review_request!(store, event)
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "subagent"} = event) do
    insert_subagent_run!(store, event)
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "repair"} = event) do
    insert_repair_attempts!(store, event)
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "rlm_plan"} = event) do
    maybe_insert_graph_summary!(store, event)
    maybe_insert_blueprint_artifact!(store, event)
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "rlm_node"} = event) do
    insert_runnable_event!(store, event)
    maybe_insert_artifacts!(store, event)
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "verification"} = event) do
    insert_tool_call!(store, event)
  end

  defp project_event_kind!(store, %TerminalEvent{kind: "error"} = event) do
    conversation = ensure_conversation!(store, event)
    insert_message!(store, event, conversation.id, "assistant", "error")
  end

  defp project_event_kind!(_store, _event), do: :ok

  defp ensure_conversation!(%Store{} = store, %TerminalEvent{} = event) do
    id = conversation_id(event)

    attrs = %{
      id: id,
      session_id: event.session_id || event.run_id,
      workflow_run_id: event.run_id,
      summary: nil,
      system_prompt: prompt_text(event),
      strategy: event.agent,
      status: conversation_status(event),
      first_message: event.detail,
      last_message_at: event.at
    }

    upsert_by_id!(store, AgentConversation, id, attrs, [])
  end

  defp insert_message!(%Store{} = store, %TerminalEvent{} = event, conversation_id, role, kind) do
    attrs = %{
      id: "message:#{event.id}",
      conversation_id: conversation_id,
      session_id: event.session_id || event.run_id,
      role: role,
      message_kind: kind,
      source_step: event.phase,
      workflow_node: workflow_node(event),
      runnable_id: runnable_id(event),
      content: message_content(event),
      content_json: event.data_json,
      stream_complete: event.kind != "chunk",
      transient: false,
      presentation_group_id: event.run_id,
      created_at: event.at
    }

    upsert_by_id!(store, AgentMessage, attrs.id, attrs, [:content_json])
  end

  defp insert_tool_call!(%Store{} = store, %TerminalEvent{} = event) do
    tool_name = tool_name(event)

    if is_binary(tool_name) and tool_name != "" do
      status = tool_status(event)

      attrs = %{
        id: tool_call_id(event, tool_name),
        session_id: event.session_id,
        conversation_id: if(event.session_id || event.run_id, do: conversation_id(event)),
        workflow_run_id: event.run_id,
        parent_tool_call_id: field(event.data_json, :parent_tool_call_id),
        tool_name: tool_name,
        tool_id: field(event.data_json, :tool_id) || field(output(event), :id),
        args_json: tool_args(event),
        result_json: tool_result(event),
        status: status,
        error_json: error_json(event),
        requested_at: if(status in ["requested", "running"], do: event.at),
        started_at: if(status in ["running"], do: event.at),
        completed_at: if(status in ["completed", "failed", "denied"], do: event.at)
      }

      upsert_by_id!(store, ToolCall, attrs.id, attrs, [:args_json, :result_json, :error_json])
    end
  end

  defp insert_review_request!(%Store{} = store, %TerminalEvent{} = event) do
    details = field(event.data_json, :details) || event.data_json

    attrs = %{
      id: field(event.data_json, :id) || "review:#{event.id}",
      session_id: event.session_id,
      workflow_run_id: event.run_id,
      tool_call_id: field(event.data_json, :tool_call_id),
      kind: field(event.data_json, :kind) || event.phase || "review",
      checkpoint: field(event.data_json, :checkpoint),
      resume_key: field(event.data_json, :resume_key),
      status: review_status(event),
      details_json: details,
      decision_json: field(event.data_json, :decision) || %{}
    }

    upsert_by_id!(store, ReviewRequest, attrs.id, attrs, [:details_json, :decision_json])
  end

  defp insert_subagent_run!(%Store{} = store, %TerminalEvent{} = event) do
    attrs = %{
      id: field(event.data_json, :subagent_id) || "subagent:#{event.id}",
      parent_session_id: event.session_id,
      parent_workflow_run_id: event.run_id,
      parent_tool_call_id: field(event.data_json, :parent_tool_call_id),
      agent_kind: field(event.data_json, :agent_kind) || "subagent",
      objective: field(event.data_json, :objective) || event.detail,
      status: subagent_status(event),
      started_at: if(event.status in ["running", "pending"], do: event.at),
      completed_at: completed_at(event),
      failed_at: failed_at(event),
      result_json: field(event.data_json, :result) || %{},
      error_json: error_json(event),
      metadata_json: event.data_json
    }

    upsert_by_id!(store, SubagentRun, attrs.id, attrs, [
      :result_json,
      :error_json,
      :metadata_json
    ])
  end

  defp insert_runnable_event!(%Store{} = store, %TerminalEvent{} = event) do
    data = stage_data(event)
    runnable = field(data, :runnable) || %{}

    if event.run_id do
      attrs = %{
        run_id: event.run_id,
        sequence: event.sequence || next_sequence!(store, RunnableEvent, event.run_id),
        runnable_id: field(runnable, :id) || field(data, :runnable_id),
        node_name: field(data, :node) || field(runnable, :node) || workflow_node(event),
        node_hash: optional_string(field(runnable, :node_hash) || field(data, :node_hash)),
        component_id: field(runnable, :component_id) || field(data, :component_id),
        component_type: field(runnable, :component_type) || field(data, :component_type),
        stage: field(event.data_json, :stage) || event.phase || "runnable",
        status: event.status,
        input_preview: preview_map(field(data, :input)),
        output_preview: preview_map(field(data, :output) || field(data, :episode)),
        error_json: error_json_from(data) |> Map.merge(error_json(event)),
        policy_json: field(runnable, :policy) || field(data, :policy) || %{},
        duration_ms: field(data, :duration_ms),
        inserted_at: event.at
      }

      %RunnableEvent{}
      |> RunnableEvent.changeset(attrs)
      |> store.repo.insert!(
        on_conflict:
          {:replace,
           [
             :runnable_id,
             :node_name,
             :node_hash,
             :component_id,
             :component_type,
             :stage,
             :status,
             :input_preview,
             :output_preview,
             :error_json,
             :policy_json,
             :duration_ms,
             :inserted_at
           ]},
        conflict_target: [:run_id, :sequence]
      )
    end
  end

  defp maybe_insert_scorecard!(%Store{} = store, %TerminalEvent{} = event) do
    case scorecard(event) do
      nil ->
        :ok

      scorecard ->
        attrs = %{
          run_id: event.run_id,
          component_id: field(scorecard, :component_id),
          objective_status: field(scorecard, :objective_status) || event.status || "unknown",
          scorecard_json: scorecard,
          created_at: event.at
        }

        %Scorecard{}
        |> Scorecard.changeset(attrs)
        |> store.repo.insert!()
    end
  end

  defp maybe_insert_artifacts!(%Store{} = store, %TerminalEvent{} = event) do
    event
    |> artifact_candidates()
    |> Enum.each(&insert_artifact!(store, event, &1))
  end

  defp maybe_insert_blueprint_artifact!(%Store{} = store, %TerminalEvent{} = event) do
    case field(event.data_json, :proposal) || field(event.data_json, :blueprint) do
      nil ->
        :ok

      blueprint ->
        insert_artifact!(store, event, %{kind: "workflow_blueprint", payload: blueprint})
    end
  end

  defp maybe_insert_graph_summary!(%Store{} = store, %TerminalEvent{} = event) do
    case graph_summary(event) do
      nil ->
        :ok

      graph ->
        insert_artifact!(store, event, %{kind: "workflow_graph", payload: graph})
        merge_run_metadata!(store, event.run_id, %{graph_summary: graph})
    end
  end

  defp insert_repair_attempts!(%Store{} = store, %TerminalEvent{} = event) do
    repairs =
      event.data_json
      |> field(:repair_history)
      |> case do
        list when is_list(list) -> list
        nil -> [stage_data(event)]
        repair -> [repair]
      end
      |> Enum.reject(&blank_map?/1)

    Enum.with_index(repairs, 0)
    |> Enum.each(fn {repair, offset} ->
      attrs = %{
        run_id: event.run_id,
        sequence: (event.sequence || next_sequence!(store, RepairAttempt, event.run_id)) + offset,
        strategy:
          field(repair, :strategy) || field(event.data_json, :strategy) || event.phase || "repair",
        reason_json: preview_map(field(repair, :reason) || field(event.data_json, :reason)),
        diagnostics_json: field(repair, :diagnostics) || field(repair, :error) || event.data_json,
        proposal_before_json: field(repair, :proposal_before) || %{},
        proposal_after_json: field(repair, :proposal_after) || field(repair, :blueprint) || %{},
        status: field(repair, :status) || event.status,
        created_at: event.at
      }

      %RepairAttempt{}
      |> RepairAttempt.changeset(attrs)
      |> store.repo.insert!(
        on_conflict:
          {:replace,
           [
             :strategy,
             :reason_json,
             :diagnostics_json,
             :proposal_before_json,
             :proposal_after_json,
             :status,
             :created_at
           ]},
        conflict_target: [:run_id, :sequence]
      )
    end)
  end

  defp insert_artifact!(%Store{} = store, %TerminalEvent{} = event, artifact) do
    payload = artifact_payload(artifact)
    path = artifact_path(artifact)
    kind = artifact_kind(artifact)
    encoded = inspect(JSON.safe(payload), limit: :infinity, printable_limit: :infinity)
    sha256 = Patch.sha256("#{path || kind}:#{encoded}")

    attrs = %{
      id: "artifact:#{event.run_id || event.session_id}:#{kind}:#{sha256}",
      run_id: event.run_id,
      session_id: event.session_id,
      path: path,
      artifact_kind: kind,
      action: field(artifact, :action) || event.phase || event.kind,
      sha256: sha256,
      byte_size: byte_size(encoded),
      artifact_blob: Term.to_blob(payload),
      metadata_json: preview_map(payload)
    }

    %RunArtifact{}
    |> RunArtifact.changeset(attrs)
    |> store.repo.insert!(
      on_conflict:
        {:replace,
         [
           :run_id,
           :session_id,
           :path,
           :artifact_kind,
           :action,
           :sha256,
           :byte_size,
           :artifact_blob,
           :metadata_json,
           :updated_at
         ]},
      conflict_target: :id
    )
  end

  defp upsert_by_id!(%Store{} = store, schema, id, attrs, merge_json_fields) when is_binary(id) do
    case store.repo.get(schema, id) do
      nil ->
        schema
        |> struct()
        |> schema.changeset(attrs)
        |> store.repo.insert!()

      existing ->
        attrs = merge_json_attrs(existing, attrs, merge_json_fields)

        existing
        |> schema.changeset(attrs)
        |> store.repo.update!()
    end
  end

  defp merge_json_attrs(existing, attrs, fields) do
    Enum.reduce(fields, attrs, fn field_name, acc ->
      current = Map.get(existing, field_name) || %{}
      incoming = Map.get(acc, field_name) || %{}
      Map.put(acc, field_name, Map.merge(current, incoming))
    end)
  end

  defp merge_run_metadata!(_store, nil, _metadata), do: :ok

  defp merge_run_metadata!(%Store{} = store, run_id, metadata) do
    case store.repo.get(WorkflowRun, run_id) do
      nil ->
        :ok

      run ->
        merged = Map.merge(run.metadata_json || %{}, JSON.safe(metadata))

        run
        |> WorkflowRun.changeset(%{metadata_json: merged})
        |> store.repo.update!()
    end
  end

  defp next_sequence!(%Store{} = store, schema, run_id) do
    query =
      from(row in schema,
        where: row.run_id == ^run_id,
        select: max(row.sequence)
      )

    case store.repo.one(query) do
      nil -> 1
      sequence -> sequence + 1
    end
  end

  defp conversation_id(%TerminalEvent{} = event),
    do: "conversation:#{event.session_id || event.run_id}"

  defp session_status(%TerminalEvent{status: "error"}), do: "failed"
  defp session_status(%TerminalEvent{status: "blocked"}), do: "blocked"

  defp session_status(%TerminalEvent{status: status}) when status in ["review", "waiting"],
    do: status

  defp session_status(%TerminalEvent{} = event) do
    if final_summary?(event), do: "completed", else: "running"
  end

  defp run_status(%TerminalEvent{status: "error"}), do: "failed"
  defp run_status(%TerminalEvent{status: "blocked"}), do: "blocked"

  defp run_status(%TerminalEvent{} = event) do
    if final_summary?(event), do: "completed", else: "running"
  end

  defp conversation_status(%TerminalEvent{status: "error"}), do: "failed"

  defp conversation_status(%TerminalEvent{} = event) do
    if final_summary?(event), do: "completed", else: "active"
  end

  defp tool_status(%TerminalEvent{status: "error"}), do: "failed"

  defp tool_status(%TerminalEvent{phase: phase}) when phase in ["observation", "complete"],
    do: "completed"

  defp tool_status(%TerminalEvent{status: "blocked"}), do: "denied"
  defp tool_status(%TerminalEvent{}), do: "running"

  defp review_status(%TerminalEvent{status: "blocked"}), do: "denied"
  defp review_status(%TerminalEvent{status: "ok"}), do: "approved"
  defp review_status(%TerminalEvent{}), do: "pending"

  defp subagent_status(%TerminalEvent{status: "error"}), do: "failed"
  defp subagent_status(%TerminalEvent{status: "ok"}), do: "completed"
  defp subagent_status(%TerminalEvent{}), do: "running"

  defp completed_at(%TerminalEvent{} = event) do
    if event.status in ["ok"] and final_summary?(event), do: event.at
  end

  defp failed_at(%TerminalEvent{status: "error"} = event), do: event.at
  defp failed_at(_event), do: nil

  defp final_summary?(%TerminalEvent{kind: "summary", phase: phase})
       when phase in ["final", "output", "scorecard", "completed"],
       do: true

  defp final_summary?(%TerminalEvent{kind: "error"}), do: true
  defp final_summary?(_event), do: false

  defp workflow_name(%TerminalEvent{} = event) do
    data_field(event, :workflow_name) || data_field(event, :workflow_id) || event.agent
  end

  defp workflow_metadata(%TerminalEvent{} = event) do
    %{
      agent: event.agent,
      session_id: event.session_id,
      last_terminal_event_id: event.id,
      last_terminal_event_title: event.title
    }
    |> maybe_put(:graph_summary, graph_summary(event))
    |> maybe_put(
      :blueprint,
      field(event.data_json, :proposal) || field(event.data_json, :blueprint)
    )
  end

  defp error_json(%TerminalEvent{} = event) do
    cond do
      event.status == "error" -> error_json_from(event.data_json)
      true -> %{}
    end
  end

  defp error_json_from(data) do
    case field(data, :error) do
      nil -> %{}
      error -> preview_map(error)
    end
  end

  defp prompt_text(%TerminalEvent{} = event) do
    data_field(event, :system_prompt) || data_field(event, :prompt)
  end

  defp message_content(%TerminalEvent{} = event) do
    event.detail || data_field(event, :reply_text) || data_field(event, :final_answer) ||
      event.title
  end

  defp workflow_node(%TerminalEvent{} = event) do
    data = stage_data(event)
    field(data, :node) || field(data, :node_name) || field(event.data_json, :workflow_node)
  end

  defp runnable_id(%TerminalEvent{} = event) do
    data = stage_data(event)
    runnable = field(data, :runnable) || %{}
    field(runnable, :id) || field(data, :runnable_id)
  end

  defp tool_name(%TerminalEvent{} = event) do
    field(event.data_json, :tool_name) ||
      field(event.data_json, :tool) ||
      field(field(event.data_json, :metadata) || %{}, :tool_name) ||
      field(output(event), :name) ||
      event.title
      |> String.replace_prefix("Tool call: ", "")
      |> String.replace_prefix("Tool observation: ", "")
  end

  defp tool_call_id(%TerminalEvent{} = event, tool_name) do
    field(event.data_json, :tool_call_id) ||
      field(output(event), :tool_call_id) ||
      field(output(event), :id) ||
      "tool_call:#{event.run_id || event.session_id}:#{tool_name}:#{event.sequence || event.id}"
  end

  defp tool_args(%TerminalEvent{} = event) do
    field(event.data_json, :args) || field(output(event), :args) ||
      field(output(event), :arguments) || %{}
  end

  defp tool_result(%TerminalEvent{} = event) do
    field(event.data_json, :result) || field(event.data_json, :output) || %{}
  end

  defp output(%TerminalEvent{} = event), do: field(event.data_json, :output) || %{}

  defp stage_data(%TerminalEvent{} = event) do
    field(event.data_json, :data) || event.data_json || %{}
  end

  defp scorecard(%TerminalEvent{} = event) do
    field(event.data_json, :scorecard) ||
      field(stage_data(event), :scorecard) ||
      field(event.data_json, :objective_scorecard)
  end

  defp graph_summary(%TerminalEvent{} = event) do
    compiled = field(event.data_json, :compiled) || field(stage_data(event), :compiled) || %{}

    field(event.data_json, :graph_summary) ||
      field(compiled, :graph_summary) ||
      field(field(compiled, :runic) || %{}, :graph_summary)
  end

  defp artifact_candidates(%TerminalEvent{} = event) do
    direct = field(event.data_json, :artifacts) || field(stage_data(event), :artifacts) || []

    paths =
      field(event.data_json, :artifact_paths) || field(stage_data(event), :artifact_paths) || []

    scorecard_path =
      event
      |> scorecard()
      |> case do
        nil -> []
        card -> List.wrap(field(card, :artifact_path))
      end

    (direct ++ Enum.map(paths ++ scorecard_path, &%{path: &1}))
    |> Enum.reject(&is_nil/1)
  end

  defp artifact_path(artifact), do: field(artifact, :path)

  defp artifact_kind(artifact),
    do: field(artifact, :kind) || field(artifact, :artifact_kind) || "output"

  defp artifact_payload(%{payload: payload}), do: payload
  defp artifact_payload(artifact), do: artifact

  defp preview_map(nil), do: %{}
  defp preview_map(value) when is_map(value), do: JSON.safe(value)
  defp preview_map(value), do: %{"value" => JSON.safe(value)}

  defp blank_map?(nil), do: true
  defp blank_map?(map) when is_map(map), do: map_size(map) == 0
  defp blank_map?(_value), do: false

  defp data_field(%TerminalEvent{} = event, key), do: field(event.data_json, key)

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(value), do: to_string(value)
end
