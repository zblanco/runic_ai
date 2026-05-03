defmodule RunicAI.Persistence.Schemas.RunArtifact do
  @moduledoc """
  Durable artifact metadata and optional artifact payload.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "run_artifacts" do
    field(:run_id, :string)
    field(:session_id, :string)
    field(:path, :string)
    field(:artifact_kind, :string)
    field(:action, :string)
    field(:sha256, :string)
    field(:byte_size, :integer)
    field(:artifact_blob, :binary)
    field(:metadata_json, :map)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(artifact, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:artifact_kind, :action])

    artifact
    |> cast(attrs, [
      :id,
      :run_id,
      :session_id,
      :path,
      :artifact_kind,
      :action,
      :sha256,
      :byte_size,
      :artifact_blob,
      :metadata_json
    ])
    |> Schema.put_new_id("artifact")
    |> Schema.normalize_strings([:artifact_kind, :action])
    |> Schema.put_json_defaults([:metadata_json])
    |> validate_required([:id, :sha256, :byte_size, :metadata_json])
  end
end
