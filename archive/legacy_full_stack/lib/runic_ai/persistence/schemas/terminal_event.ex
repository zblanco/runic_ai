defmodule RunicAI.Persistence.Schemas.TerminalEvent do
  @moduledoc """
  Durable normalized terminal/presentation event.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "terminal_events" do
    field(:session_id, :string)
    field(:run_id, :string)
    field(:sequence, :integer)
    field(:agent, :string)
    field(:kind, :string)
    field(:phase, :string)
    field(:status, :string)
    field(:title, :string)
    field(:detail, :string)
    field(:data_json, :map)
    field(:at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:agent, :kind, :phase, :status])

    event
    |> cast(attrs, [
      :id,
      :session_id,
      :run_id,
      :sequence,
      :agent,
      :kind,
      :phase,
      :status,
      :title,
      :detail,
      :data_json,
      :at
    ])
    |> Schema.put_new_id("terminal_event")
    |> Schema.normalize_strings([:agent, :kind, :phase, :status])
    |> Schema.put_json_defaults([:data_json])
    |> validate_inclusion(:agent, ["standard", "assistant", "rlm"])
    |> validate_inclusion(:kind, [
      "status",
      "message",
      "tool",
      "hitl",
      "rlm_plan",
      "rlm_node",
      "verification",
      "repair",
      "subagent",
      "chunk",
      "error",
      "summary"
    ])
    |> Schema.validate_status([:pending, :running, :ok, :review, :waiting, :blocked, :error])
    |> validate_required([:id, :agent, :kind, :status, :title, :data_json, :at])
  end
end
