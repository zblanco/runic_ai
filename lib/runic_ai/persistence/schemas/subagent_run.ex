defmodule RunicAI.Persistence.Schemas.SubagentRun do
  @moduledoc """
  Durable child-agent launch and completion record.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "subagent_runs" do
    field(:parent_session_id, :string)
    field(:parent_workflow_run_id, :string)
    field(:parent_tool_call_id, :string)
    field(:agent_kind, :string)
    field(:objective, :string)
    field(:status, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:failed_at, :utc_datetime_usec)
    field(:result_json, :map)
    field(:error_json, :map)
    field(:metadata_json, :map)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:agent_kind, :status])

    run
    |> cast(attrs, [
      :id,
      :parent_session_id,
      :parent_workflow_run_id,
      :parent_tool_call_id,
      :agent_kind,
      :objective,
      :status,
      :started_at,
      :completed_at,
      :failed_at,
      :result_json,
      :error_json,
      :metadata_json
    ])
    |> Schema.put_new_id("subagent")
    |> Schema.normalize_strings([:agent_kind, :status])
    |> Schema.put_json_defaults([:result_json, :error_json, :metadata_json])
    |> Schema.validate_status([:running, :completed, :failed, :blocked, :cancelled])
    |> validate_required([:id, :agent_kind, :status, :result_json, :error_json, :metadata_json])
  end
end
