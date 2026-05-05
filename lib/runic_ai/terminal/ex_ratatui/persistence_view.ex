defmodule RunicAI.Terminal.ExRatatui.PersistenceView do
  @moduledoc """
  Stable TUI-facing projections over persistence schemas.

  Views should consume these maps instead of reaching into Ecto schemas. That
  keeps the rendering layer insulated from storage evolution.
  """

  alias RunicAI.Persistence.Schemas.ManagedWorkflow
  alias RunicAI.Persistence.Schemas.AgentMessage
  alias RunicAI.Persistence.Schemas.RepairAttempt
  alias RunicAI.Persistence.Schemas.ReviewRequest
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Persistence.Schemas.RunnableEvent
  alias RunicAI.Persistence.Schemas.Scorecard
  alias RunicAI.Persistence.Schemas.TerminalEvent
  alias RunicAI.Persistence.Schemas.ToolCall
  alias RunicAI.Persistence.Schemas.WorkflowRun

  @spec run(WorkflowRun.t()) :: map()
  def run(%WorkflowRun{} = run) do
    metadata = run.metadata_json || %{}

    %{
      id: run.id,
      workflow_key: run.workflow_key,
      workflow_name: run.workflow_name,
      session_id: run.session_id,
      status: run.status || "unknown",
      agent: metadata["agent"] || metadata[:agent],
      objective: metadata["objective"] || metadata[:objective],
      latest_event_title:
        metadata["last_terminal_event_title"] || metadata[:last_terminal_event_title],
      started_at: run.started_at || run.inserted_at,
      completed_at: run.completed_at,
      failed_at: run.failed_at,
      error: run.error_json || %{},
      metadata: metadata
    }
  end

  @spec terminal_event(TerminalEvent.t()) :: map()
  def terminal_event(%TerminalEvent{} = event) do
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

  @spec message(AgentMessage.t()) :: map()
  def message(%AgentMessage{} = message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      session_id: message.session_id,
      role: message.role,
      message_kind: message.message_kind,
      source_step: message.source_step,
      workflow_node: message.workflow_node,
      content: message.content,
      content_json: message.content_json || %{},
      stream_complete: message.stream_complete,
      transient: message.transient,
      presentation_group_id: message.presentation_group_id,
      created_at: message.created_at
    }
  end

  @spec runnable_event(RunnableEvent.t()) :: map()
  def runnable_event(%RunnableEvent{} = event) do
    %{
      run_id: event.run_id,
      sequence: event.sequence,
      runnable_id: event.runnable_id,
      node_name: event.node_name,
      component_id: event.component_id,
      component_type: event.component_type,
      stage: event.stage,
      status: event.status,
      input_preview: event.input_preview,
      output_preview: event.output_preview,
      error: event.error_json || %{},
      policy: event.policy_json || %{},
      duration_ms: event.duration_ms,
      inserted_at: event.inserted_at
    }
  end

  @spec tool_call(ToolCall.t()) :: map()
  def tool_call(%ToolCall{} = call) do
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

  @spec artifact(RunArtifact.t()) :: map()
  def artifact(%RunArtifact{} = artifact) do
    %{
      id: artifact.id,
      run_id: artifact.run_id,
      session_id: artifact.session_id,
      path: artifact.path,
      kind: artifact.artifact_kind,
      action: artifact.action,
      sha256: artifact.sha256,
      byte_size: artifact.byte_size,
      metadata: artifact.metadata_json || %{},
      inserted_at: artifact.inserted_at,
      updated_at: artifact.updated_at
    }
  end

  @spec scorecard(Scorecard.t()) :: map()
  def scorecard(%Scorecard{} = scorecard) do
    %{
      id: scorecard.id,
      run_id: scorecard.run_id,
      component_id: scorecard.component_id,
      objective_status: scorecard.objective_status,
      data: scorecard.scorecard_json || %{},
      created_at: scorecard.created_at
    }
  end

  @spec repair_attempt(RepairAttempt.t()) :: map()
  def repair_attempt(%RepairAttempt{} = repair) do
    %{
      id: repair.id,
      run_id: repair.run_id,
      sequence: repair.sequence,
      strategy: repair.strategy,
      reason: repair.reason_json || %{},
      diagnostics: repair.diagnostics_json || %{},
      proposal_before: repair.proposal_before_json || %{},
      proposal_after: repair.proposal_after_json || %{},
      status: repair.status,
      created_at: repair.created_at
    }
  end

  @spec review_request(ReviewRequest.t()) :: map()
  def review_request(%ReviewRequest{} = request) do
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
      inserted_at: request.inserted_at,
      updated_at: request.updated_at
    }
  end

  @spec managed_workflow(ManagedWorkflow.t()) :: map()
  def managed_workflow(%ManagedWorkflow{} = workflow) do
    %{
      id: workflow.id,
      workflow_key: workflow.workflow_key,
      workflow_name: workflow.workflow_name,
      status: workflow.status,
      trigger: (workflow.metadata_json || %{})["trigger"],
      restart_policy: workflow.restart_policy,
      checkpoint_strategy: workflow.checkpoint_strategy,
      last_run_id: workflow.last_run_id,
      metadata: workflow.metadata_json || %{},
      inserted_at: workflow.inserted_at,
      updated_at: workflow.updated_at
    }
  end

  @spec eval_record(map()) :: map()
  def eval_record(record) when is_map(record) do
    run = Map.get(record, :run)
    scorecards = Map.get(record, :scorecards, [])
    latest = List.last(scorecards)

    %{
      run: if(match?(%WorkflowRun{}, run), do: run(run), else: run),
      objective_status: if(latest, do: latest.objective_status, else: "unknown"),
      scorecard_count: length(scorecards),
      message_count: metric(record, :message_count),
      tool_call_count: metric(record, :tool_call_count),
      artifact_count: metric(record, :artifact_count),
      repair_count: metric(record, :repair_count)
    }
  end

  defp metric(record, key), do: record |> Map.get(:metrics, %{}) |> Map.get(key, 0)
end
