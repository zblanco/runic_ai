defmodule RunicAI.Persistence.SQLite.Migrations.AddWorkflowEvaluationRecords do
  use Ecto.Migration

  def change do
    create table(:workflow_eval_records, primary_key: false) do
      add :id, :string, primary_key: true
      add :suite, :string, null: false
      add :case_id, :string, null: false
      add :task_family, :string
      add :arm, :string, null: false
      add :model, :string
      add :status, :string, null: false
      add :candidate_id, :string
      add :metrics_json, :map, null: false
      add :diagnostics_json, :map, null: false
      add :artifacts_json, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:workflow_eval_records, [:suite, :case_id, :arm])
    create index(:workflow_eval_records, [:task_family, :model])
    create index(:workflow_eval_records, [:candidate_id])

    create table(:workflow_optimization_candidates, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :version, :integer, null: false
      add :task_family, :string
      add :status, :string, null: false
      add :pareto, :boolean, null: false, default: false
      add :parent_ids_json, :map, null: false
      add :modules_json, :map, null: false
      add :metrics_json, :map, null: false
      add :feedback_json, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workflow_optimization_candidates, [:name, :version, :task_family])
    create index(:workflow_optimization_candidates, [:task_family, :pareto])
  end
end
