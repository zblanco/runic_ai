defmodule RunicAI.Persistence.Schemas.WorkflowRevisionProjection do
  @moduledoc """
  Regenerable human or agent view derived from a canonical workflow revision.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "workflow_revision_projections" do
    field(:revision_id, :string)
    field(:projection_kind, :string)
    field(:projection_hash, :string)
    field(:content, :string)
    field(:metadata_json, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(projection, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:projection_kind])

    projection
    |> cast(attrs, [
      :id,
      :revision_id,
      :projection_kind,
      :projection_hash,
      :content,
      :metadata_json,
      :inserted_at
    ])
    |> Schema.put_new_id("workflow_revision_projection")
    |> Schema.normalize_strings([:projection_kind])
    |> Schema.put_json_defaults([:metadata_json])
    |> validate_required([
      :id,
      :revision_id,
      :projection_kind,
      :projection_hash,
      :content,
      :metadata_json,
      :inserted_at
    ])
  end
end
