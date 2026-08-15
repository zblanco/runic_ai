defmodule RunicAI.Persistence.Schemas.WorkflowOptimizationCandidate do
  @moduledoc "Versioned GEPA-style textual-module candidate and aggregate feedback."

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "workflow_optimization_candidates" do
    field(:name, :string)
    field(:version, :integer)
    field(:task_family, :string)
    field(:status, :string)
    field(:pareto, :boolean)
    field(:parent_ids_json, :map)
    field(:modules_json, :map)
    field(:metrics_json, :map)
    field(:feedback_json, :map)

    timestamps()
  end

  def changeset(candidate, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:status])

    candidate
    |> cast(attrs, [
      :id,
      :name,
      :version,
      :task_family,
      :status,
      :pareto,
      :parent_ids_json,
      :modules_json,
      :metrics_json,
      :feedback_json
    ])
    |> Schema.put_new_id("workflow_optimization_candidate")
    |> Schema.normalize_strings([:status])
    |> Schema.put_json_defaults([
      :parent_ids_json,
      :modules_json,
      :metrics_json,
      :feedback_json
    ])
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:status, ["active", "retained", "rejected"])
    |> validate_required([
      :id,
      :name,
      :version,
      :status,
      :pareto,
      :parent_ids_json,
      :modules_json,
      :metrics_json,
      :feedback_json
    ])
  end
end
