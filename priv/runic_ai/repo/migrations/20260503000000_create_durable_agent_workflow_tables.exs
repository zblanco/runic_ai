defmodule RunicAI.Persistence.SQLite.Migrations.CreateDurableAgentWorkflowTables do
  use Ecto.Migration

  def change do
    create table(:runic_ai_schema_versions, primary_key: false) do
      add :version, :integer, primary_key: true
      add :migrated_at, :utc_datetime_usec, null: false
    end

    create table(:agent_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :agent_kind, :string, null: false
      add :workspace_root, :text
      add :objective, :text
      add :model, :string
      add :status, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :metadata_json, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create table(:workflow_runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :workflow_key, :string, null: false
      add :workflow_name, :string
      add :workflow_id_blob, :binary, null: false
      add :session_id, :string
      add :managed_workflow_id, :string
      add :status, :string, null: false
      add :trigger, :string
      add :input_blob, :binary
      add :metadata_json, :map, null: false
      add :last_event_sequence, :integer
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :last_checkpointed_at, :utc_datetime_usec
      add :error_json, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_runs, [:workflow_key])
    create index(:workflow_runs, [:session_id])
    create index(:workflow_runs, [:managed_workflow_id])

    create table(:managed_workflows, primary_key: false) do
      add :id, :string, primary_key: true
      add :workflow_key, :string, null: false
      add :workflow_name, :string
      add :scope_type, :string
      add :scope_id, :string
      add :status, :string, null: false
      add :definition_kind, :string, null: false
      add :definition_blob, :binary
      add :checkpoint_strategy, :string
      add :restart_policy, :string
      add :last_run_id, :string
      add :metadata_json, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:managed_workflows, [:workflow_key])

    create table(:agent_conversations, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string, null: false
      add :workflow_run_id, :string
      add :summary, :text
      add :system_prompt, :text
      add :strategy, :string
      add :status, :string, null: false
      add :first_message, :text
      add :last_message_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_conversations, [:session_id])
    create index(:agent_conversations, [:workflow_run_id])

    create table(:agent_messages, primary_key: false) do
      add :id, :string, primary_key: true
      add :conversation_id, :string
      add :session_id, :string, null: false
      add :role, :string, null: false
      add :message_kind, :string, null: false
      add :source_step, :string
      add :workflow_node, :string
      add :runnable_id, :string
      add :content, :text
      add :content_json, :map, null: false
      add :stream_complete, :boolean, null: false, default: false
      add :transient, :boolean, null: false, default: false
      add :supersedes_message_id, :string
      add :presentation_group_id, :string
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:agent_messages, [:conversation_id])
    create index(:agent_messages, [:session_id])
    create index(:agent_messages, [:workflow_node])
    create index(:agent_messages, [:runnable_id])

    create table(:agent_message_chunks) do
      add :message_id, :string, null: false
      add :sequence, :integer, null: false
      add :chunk_kind, :string, null: false
      add :content, :text
      add :payload_json, :map, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:agent_message_chunks, [:message_id, :sequence])

    create table(:tool_calls, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string
      add :conversation_id, :string
      add :workflow_run_id, :string
      add :parent_tool_call_id, :string
      add :tool_name, :string, null: false
      add :tool_id, :string
      add :args_json, :map, null: false
      add :result_json, :map, null: false
      add :status, :string, null: false
      add :error_json, :map, null: false
      add :requested_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
    end

    create index(:tool_calls, [:workflow_run_id])
    create index(:tool_calls, [:session_id])
    create index(:tool_calls, [:tool_name])

    create table(:review_requests, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string
      add :workflow_run_id, :string
      add :tool_call_id, :string
      add :kind, :string, null: false
      add :checkpoint, :string
      add :resume_key, :string
      add :status, :string, null: false
      add :details_json, :map, null: false
      add :decision_json, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:review_requests, [:session_id])
    create index(:review_requests, [:workflow_run_id])
    create index(:review_requests, [:resume_key])

    create table(:subagent_runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :parent_session_id, :string
      add :parent_workflow_run_id, :string
      add :parent_tool_call_id, :string
      add :agent_kind, :string, null: false
      add :objective, :text
      add :status, :string, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :result_json, :map, null: false
      add :error_json, :map, null: false
      add :metadata_json, :map, null: false
    end

    create index(:subagent_runs, [:parent_session_id])
    create index(:subagent_runs, [:parent_workflow_run_id])

    create table(:workflow_events) do
      add :run_id, :string, null: false
      add :sequence, :integer, null: false
      add :event_type, :string, null: false
      add :node_name, :string
      add :node_hash, :string
      add :runnable_id, :string
      add :component_id, :string
      add :component_type, :string
      add :payload_blob, :binary, null: false
      add :payload_json, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workflow_events, [:run_id, :sequence])
    create index(:workflow_events, [:node_name])
    create index(:workflow_events, [:runnable_id])
    create index(:workflow_events, [:component_id])
    create index(:workflow_events, [:event_type])

    create table(:workflow_snapshots) do
      add :run_id, :string, null: false
      add :event_sequence, :integer, null: false
      add :workflow_blob, :binary, null: false
      add :metadata_json, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workflow_snapshots, [:run_id, :event_sequence])

    create table(:workflow_facts, primary_key: false) do
      add :hash_key, :string, primary_key: true
      add :run_id, :string
      add :producer_node, :string
      add :component_id, :string
      add :value_blob, :binary, null: false
      add :preview_json, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:workflow_facts, [:run_id])

    create table(:runnable_events) do
      add :run_id, :string, null: false
      add :sequence, :integer, null: false
      add :runnable_id, :string
      add :node_name, :string
      add :node_hash, :string
      add :component_id, :string
      add :component_type, :string
      add :stage, :string, null: false
      add :status, :string, null: false
      add :input_preview, :map, null: false
      add :output_preview, :map, null: false
      add :error_json, :map, null: false
      add :policy_json, :map, null: false
      add :duration_ms, :integer
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:runnable_events, [:run_id, :sequence])
    create index(:runnable_events, [:runnable_id])
    create index(:runnable_events, [:node_name])
    create index(:runnable_events, [:status])

    create table(:run_artifacts, primary_key: false) do
      add :id, :string, primary_key: true
      add :run_id, :string
      add :session_id, :string
      add :path, :text
      add :artifact_kind, :string
      add :action, :string
      add :sha256, :string, null: false
      add :byte_size, :integer, null: false
      add :artifact_blob, :binary
      add :metadata_json, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:run_artifacts, [:run_id])
    create index(:run_artifacts, [:session_id])
    create index(:run_artifacts, [:path])
    create index(:run_artifacts, [:sha256])

    create table(:scorecards) do
      add :run_id, :string, null: false
      add :component_id, :string
      add :objective_status, :string, null: false
      add :scorecard_json, :map, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:scorecards, [:run_id])
    create index(:scorecards, [:objective_status])

    create table(:repair_attempts) do
      add :run_id, :string, null: false
      add :sequence, :integer, null: false
      add :strategy, :string, null: false
      add :reason_json, :map, null: false
      add :diagnostics_json, :map, null: false
      add :proposal_before_json, :map, null: false
      add :proposal_after_json, :map, null: false
      add :status, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:repair_attempts, [:run_id, :sequence])

    create table(:terminal_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, :string
      add :run_id, :string
      add :sequence, :integer
      add :agent, :string, null: false
      add :kind, :string, null: false
      add :phase, :string
      add :status, :string, null: false
      add :title, :text, null: false
      add :detail, :text
      add :data_json, :map, null: false
      add :at, :utc_datetime_usec, null: false
    end

    create index(:terminal_events, [:session_id])
    create index(:terminal_events, [:run_id])

    create unique_index(:terminal_events, [:run_id, :sequence],
             where: "run_id IS NOT NULL AND sequence IS NOT NULL"
           )

    create table(:coding_events) do
      add :kind, :string, null: false
      add :status, :string
      add :artifact_ref, :string
      add :event_blob, :binary, null: false
      add :searchable_text, :text, null: false
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create index(:coding_events, [:kind])
    create index(:coding_events, [:artifact_ref])

    execute(
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS terminal_events_fts
      USING fts5(title, detail, data, content='terminal_events', content_rowid='rowid')
      """,
      "DROP TABLE IF EXISTS terminal_events_fts"
    )

    execute(
      """
      CREATE TRIGGER IF NOT EXISTS terminal_events_ai AFTER INSERT ON terminal_events BEGIN
        INSERT INTO terminal_events_fts(rowid, title, detail, data)
        VALUES (new.rowid, new.title, new.detail, json_extract(new.data_json, '$'));
      END
      """,
      "DROP TRIGGER IF EXISTS terminal_events_ai"
    )

    execute(
      """
      CREATE TRIGGER IF NOT EXISTS terminal_events_ad AFTER DELETE ON terminal_events BEGIN
        INSERT INTO terminal_events_fts(terminal_events_fts, rowid, title, detail, data)
        VALUES('delete', old.rowid, old.title, old.detail, json_extract(old.data_json, '$'));
      END
      """,
      "DROP TRIGGER IF EXISTS terminal_events_ad"
    )

    execute(
      """
      CREATE TRIGGER IF NOT EXISTS terminal_events_au AFTER UPDATE ON terminal_events BEGIN
        INSERT INTO terminal_events_fts(terminal_events_fts, rowid, title, detail, data)
        VALUES('delete', old.rowid, old.title, old.detail, json_extract(old.data_json, '$'));
        INSERT INTO terminal_events_fts(rowid, title, detail, data)
        VALUES (new.rowid, new.title, new.detail, json_extract(new.data_json, '$'));
      END
      """,
      "DROP TRIGGER IF EXISTS terminal_events_au"
    )
  end
end
