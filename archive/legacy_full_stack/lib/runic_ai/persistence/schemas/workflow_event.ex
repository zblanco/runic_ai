defmodule RunicAI.Persistence.Schemas.WorkflowEvent do
  @moduledoc """
  Append-only Runic workflow event row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  schema "workflow_events" do
    field(:run_id, :string)
    field(:sequence, :integer)
    field(:event_type, :string)
    field(:node_name, :string)
    field(:node_hash, :string)
    field(:runnable_id, :string)
    field(:component_id, :string)
    field(:component_type, :string)
    field(:payload_blob, :binary)
    field(:payload_json, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :run_id,
      :sequence,
      :event_type,
      :node_name,
      :node_hash,
      :runnable_id,
      :component_id,
      :component_type,
      :payload_blob,
      :payload_json,
      :inserted_at
    ])
    |> Schema.put_json_defaults([:payload_json])
    |> validate_required([
      :run_id,
      :sequence,
      :event_type,
      :payload_blob,
      :payload_json,
      :inserted_at
    ])
  end
end
