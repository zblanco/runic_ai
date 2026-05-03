defmodule RunicAI.Persistence.Schemas.CodingEvent do
  @moduledoc """
  Compatibility event row for the existing coding persistence behaviour.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "coding_events" do
    field(:kind, :string)
    field(:status, :string)
    field(:artifact_ref, :string)
    field(:event_blob, :binary)
    field(:searchable_text, :string)
    field(:recorded_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:kind, :status, :artifact_ref, :event_blob, :searchable_text, :recorded_at])
    |> validate_required([:kind, :event_blob, :searchable_text, :recorded_at])
  end
end
