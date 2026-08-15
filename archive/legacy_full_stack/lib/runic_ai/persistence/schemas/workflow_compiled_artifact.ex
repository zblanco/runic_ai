defmodule RunicAI.Persistence.Schemas.WorkflowCompiledArtifact do
  @moduledoc """
  Immutable compiled artifact and semantic-to-runtime source map for a revision.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "workflow_compiled_artifacts" do
    field(:revision_id, :string)
    field(:compiled_hash, :string)
    field(:catalog_hash, :string)
    field(:artifact_blob, :binary)
    field(:source_map_json, :map)
    field(:metadata_json, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :id,
      :revision_id,
      :compiled_hash,
      :catalog_hash,
      :artifact_blob,
      :source_map_json,
      :metadata_json,
      :inserted_at
    ])
    |> Schema.put_new_id("workflow_compiled_artifact")
    |> Schema.put_json_defaults([:source_map_json, :metadata_json])
    |> validate_required([
      :id,
      :revision_id,
      :compiled_hash,
      :artifact_blob,
      :source_map_json,
      :metadata_json,
      :inserted_at
    ])
  end
end
