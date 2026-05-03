defmodule RunicAI.Persistence.Schemas.AgentMessageChunk do
  @moduledoc """
  Stream chunk for an agent message.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  schema "agent_message_chunks" do
    field(:message_id, :string)
    field(:sequence, :integer)
    field(:chunk_kind, :string)
    field(:content, :string)
    field(:payload_json, :map)
    field(:created_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(chunk, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:chunk_kind])

    chunk
    |> cast(attrs, [:message_id, :sequence, :chunk_kind, :content, :payload_json, :created_at])
    |> Schema.normalize_strings([:chunk_kind])
    |> Schema.put_json_defaults([:payload_json])
    |> validate_required([:message_id, :sequence, :chunk_kind, :payload_json, :created_at])
  end
end
