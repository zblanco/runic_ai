defmodule RunicAI.Persistence.Schemas.WorkflowDefinitionRevision do
  @moduledoc """
  Immutable canonical semantic definition for one managed-workflow revision.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "workflow_definition_revisions" do
    field(:managed_workflow_id, :string)
    field(:revision, :integer)
    field(:parent_revision_id, :string)
    field(:semantic_hash, :string)
    field(:contract_hash, :string)
    field(:catalog_hash, :string)
    field(:ir_json, :map)
    field(:created_by, :string)
    field(:metadata_json, :map)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :id,
      :managed_workflow_id,
      :revision,
      :parent_revision_id,
      :semantic_hash,
      :contract_hash,
      :catalog_hash,
      :ir_json,
      :created_by,
      :metadata_json
    ])
    |> Schema.put_new_id("workflow_revision")
    |> Schema.put_json_defaults([:ir_json, :metadata_json])
    |> validate_number(:revision, greater_than: 0)
    |> validate_required([
      :id,
      :managed_workflow_id,
      :revision,
      :semantic_hash,
      :ir_json,
      :metadata_json
    ])
  end
end
