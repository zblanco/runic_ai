defmodule RunicAI.Persistence.Schemas.WorkflowRevisionEvent do
  @moduledoc """
  Append-only lifecycle event for a semantic workflow revision.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "workflow_revision_events" do
    field(:managed_workflow_id, :string)
    field(:revision_id, :string)
    field(:action, :string)
    field(:actor, :string)
    field(:data_json, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:action])

    event
    |> cast(attrs, [
      :id,
      :managed_workflow_id,
      :revision_id,
      :action,
      :actor,
      :data_json,
      :inserted_at
    ])
    |> Schema.put_new_id("workflow_revision_event")
    |> Schema.normalize_strings([:action])
    |> Schema.put_json_defaults([:data_json])
    |> validate_inclusion(:action, [
      "drafted",
      "revised",
      "review_requested",
      "approved",
      "rejected",
      "activated",
      "closed",
      "archived",
      "revalidated",
      "catalog_migrated",
      "forked"
    ])
    |> validate_required([
      :id,
      :managed_workflow_id,
      :revision_id,
      :action,
      :data_json,
      :inserted_at
    ])
  end
end
