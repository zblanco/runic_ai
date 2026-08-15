defmodule RunicAI.Persistence.SQLite.Migrations.AddWorkflowChildInvocations do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :parent_run_id, :string
      add :parent_node_id, :string
      add :invocation_key, :string
      add :attempt, :integer, null: false, default: 1
      add :supersedes_run_id, :string
      add :output_blob, :binary
    end

    create index(:workflow_runs, [:parent_run_id])
    create index(:workflow_runs, [:supersedes_run_id])

    create unique_index(
             :workflow_runs,
             [:parent_run_id, :invocation_key, :attempt],
             where: "invocation_key IS NOT NULL",
             name: :workflow_runs_invocation_attempt_index
           )
  end
end
