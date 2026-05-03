defmodule RunicAI.Persistence.Schemas.AgentMessage do
  @moduledoc """
  Durable message row for agent and chat observability.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "agent_messages" do
    field(:conversation_id, :string)
    field(:session_id, :string)
    field(:role, :string)
    field(:message_kind, :string)
    field(:source_step, :string)
    field(:workflow_node, :string)
    field(:runnable_id, :string)
    field(:content, :string)
    field(:content_json, :map)
    field(:stream_complete, :boolean, default: false)
    field(:transient, :boolean, default: false)
    field(:supersedes_message_id, :string)
    field(:presentation_group_id, :string)
    field(:created_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:role, :message_kind])

    message
    |> cast(attrs, [
      :id,
      :conversation_id,
      :session_id,
      :role,
      :message_kind,
      :source_step,
      :workflow_node,
      :runnable_id,
      :content,
      :content_json,
      :stream_complete,
      :transient,
      :supersedes_message_id,
      :presentation_group_id,
      :created_at
    ])
    |> Schema.put_new_id("message")
    |> Schema.normalize_strings([:role, :message_kind])
    |> Schema.put_json_defaults([:content_json])
    |> validate_required([:id, :session_id, :role, :message_kind, :created_at, :content_json])
  end
end
