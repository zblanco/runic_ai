defmodule RunicAI.Persistence.Schemas.AgentConversation do
  @moduledoc """
  Durable conversation identity for an agent session.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_conversations" do
    field(:session_id, :string)
    field(:workflow_run_id, :string)
    field(:summary, :string)
    field(:system_prompt, :string)
    field(:strategy, :string)
    field(:status, :string)
    field(:first_message, :string)
    field(:last_message_at, :utc_datetime_usec)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(conversation, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:strategy, :status])

    conversation
    |> cast(attrs, [
      :id,
      :session_id,
      :workflow_run_id,
      :summary,
      :system_prompt,
      :strategy,
      :status,
      :first_message,
      :last_message_at
    ])
    |> Schema.put_new_id("conversation")
    |> Schema.normalize_strings([:strategy, :status])
    |> Schema.validate_status([:active, :completed, :failed, :archived])
    |> validate_required([:id, :session_id, :status])
  end
end
