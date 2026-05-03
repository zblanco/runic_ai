defmodule RunicAI.Persistence.Schemas.AgentSession do
  @moduledoc """
  Durable top-level agent session.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_sessions" do
    field(:agent_kind, :string)
    field(:workspace_root, :string)
    field(:objective, :string)
    field(:model, :string)
    field(:status, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:failed_at, :utc_datetime_usec)
    field(:metadata_json, :map)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:agent_kind, :status])

    session
    |> cast(attrs, [
      :id,
      :agent_kind,
      :workspace_root,
      :objective,
      :model,
      :status,
      :started_at,
      :completed_at,
      :failed_at,
      :metadata_json
    ])
    |> Schema.put_new_id("session")
    |> Schema.normalize_strings([:agent_kind, :status])
    |> Schema.put_json_defaults([:metadata_json])
    |> validate_inclusion(:agent_kind, ["standard", "assistant", "rlm", "subagent"])
    |> Schema.validate_status([
      :running,
      :completed,
      :failed,
      :blocked,
      :review,
      :waiting,
      :paused,
      :cancelled
    ])
    |> validate_required([:id, :agent_kind, :status, :started_at, :metadata_json])
  end
end
