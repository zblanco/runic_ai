defmodule RunicAI.Persistence.Schemas.WorkflowEvalRecord do
  @moduledoc "One durable workflow-substrate or routing evaluation row."

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "workflow_eval_records" do
    field(:suite, :string)
    field(:case_id, :string)
    field(:task_family, :string)
    field(:arm, :string)
    field(:model, :string)
    field(:status, :string)
    field(:candidate_id, :string)
    field(:metrics_json, :map)
    field(:diagnostics_json, :map)
    field(:artifacts_json, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:arm, :status])

    record
    |> cast(attrs, [
      :id,
      :suite,
      :case_id,
      :task_family,
      :arm,
      :model,
      :status,
      :candidate_id,
      :metrics_json,
      :diagnostics_json,
      :artifacts_json,
      :inserted_at
    ])
    |> Schema.put_new_id("workflow_eval")
    |> Schema.normalize_strings([:arm, :status])
    |> Schema.put_json_defaults([:metrics_json, :diagnostics_json, :artifacts_json])
    |> Schema.validate_status([:pass, :fail, :blocked, :error])
    |> validate_required([
      :id,
      :suite,
      :case_id,
      :arm,
      :status,
      :metrics_json,
      :diagnostics_json,
      :artifacts_json,
      :inserted_at
    ])
  end
end
