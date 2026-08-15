defmodule RunicAI.Persistence.SQLite.Migrations.AddWorkflowDefinitionRevisions do
  use Ecto.Migration

  def change do
    alter table(:managed_workflows) do
      add :latest_revision_id, :string
      add :review_revision_id, :string
      add :active_revision_id, :string
    end

    create table(:workflow_definition_revisions, primary_key: false) do
      add :id, :string, primary_key: true
      add :managed_workflow_id, :string, null: false
      add :revision, :integer, null: false
      add :parent_revision_id, :string
      add :semantic_hash, :string, null: false
      add :contract_hash, :string
      add :catalog_hash, :string
      add :ir_json, :map, null: false
      add :created_by, :string
      add :metadata_json, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workflow_definition_revisions, [:managed_workflow_id, :revision])
    create unique_index(:workflow_definition_revisions, [:managed_workflow_id, :semantic_hash])
    create index(:workflow_definition_revisions, [:parent_revision_id])

    create table(:workflow_operation_batches, primary_key: false) do
      add :id, :string, primary_key: true
      add :managed_workflow_id, :string, null: false
      add :base_revision_id, :string, null: false
      add :result_revision_id, :string, null: false
      add :actor, :string
      add :base_hash, :string, null: false
      add :result_hash, :string, null: false
      add :data_json, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:workflow_operation_batches, [:managed_workflow_id, :inserted_at])
    create index(:workflow_operation_batches, [:base_revision_id])
    create unique_index(:workflow_operation_batches, [:result_revision_id])

    create table(:workflow_revision_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :managed_workflow_id, :string, null: false
      add :revision_id, :string, null: false
      add :action, :string, null: false
      add :actor, :string
      add :data_json, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:workflow_revision_events, [:managed_workflow_id, :inserted_at])
    create index(:workflow_revision_events, [:revision_id, :inserted_at])

    create table(:workflow_compiled_artifacts, primary_key: false) do
      add :id, :string, primary_key: true
      add :revision_id, :string, null: false
      add :compiled_hash, :string, null: false
      add :catalog_hash, :string
      add :artifact_blob, :binary, null: false
      add :source_map_json, :map, null: false
      add :metadata_json, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workflow_compiled_artifacts, [:revision_id, :compiled_hash])
    create index(:workflow_compiled_artifacts, [:catalog_hash])

    create table(:workflow_revision_projections, primary_key: false) do
      add :id, :string, primary_key: true
      add :revision_id, :string, null: false
      add :projection_kind, :string, null: false
      add :projection_hash, :string, null: false
      add :content, :text, null: false
      add :metadata_json, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workflow_revision_projections, [:revision_id, :projection_kind])

    alter table(:workflow_runs) do
      add :definition_revision_id, :string
      add :definition_revision, :integer
      add :definition_hash, :string
      add :compiled_artifact_id, :string
      add :compiled_hash, :string
      add :catalog_hash, :string
    end

    create index(:workflow_runs, [:definition_revision_id])
    create index(:workflow_runs, [:compiled_artifact_id])
  end
end
