defmodule RunicAI.Persistence.Schemas.WorkflowSnapshot do
  @moduledoc """
  Coarse workflow or event-log snapshot.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  schema "workflow_snapshots" do
    field(:run_id, :string)
    field(:event_sequence, :integer)
    field(:workflow_blob, :binary)
    field(:metadata_json, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:run_id, :event_sequence, :workflow_blob, :metadata_json, :inserted_at])
    |> Schema.put_json_defaults([:metadata_json])
    |> validate_required([:run_id, :event_sequence, :workflow_blob, :metadata_json, :inserted_at])
  end
end
