defmodule RunicAI.Persistence.Schemas.WorkflowOperationBatch do
  @moduledoc """
  Append-only typed edit transaction linking two semantic revisions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "workflow_operation_batches" do
    field(:managed_workflow_id, :string)
    field(:base_revision_id, :string)
    field(:result_revision_id, :string)
    field(:actor, :string)
    field(:base_hash, :string)
    field(:result_hash, :string)
    field(:data_json, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :id,
      :managed_workflow_id,
      :base_revision_id,
      :result_revision_id,
      :actor,
      :base_hash,
      :result_hash,
      :data_json,
      :inserted_at
    ])
    |> Schema.put_new_id("workflow_operation_batch")
    |> Schema.put_json_defaults([:data_json])
    |> validate_required([
      :id,
      :managed_workflow_id,
      :base_revision_id,
      :result_revision_id,
      :base_hash,
      :result_hash,
      :data_json,
      :inserted_at
    ])
  end
end
