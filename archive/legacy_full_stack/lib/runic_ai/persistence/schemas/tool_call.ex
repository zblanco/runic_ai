defmodule RunicAI.Persistence.Schemas.ToolCall do
  @moduledoc """
  Durable tool-call audit record.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "tool_calls" do
    field(:session_id, :string)
    field(:conversation_id, :string)
    field(:workflow_run_id, :string)
    field(:parent_tool_call_id, :string)
    field(:tool_name, :string)
    field(:tool_id, :string)
    field(:args_json, :map)
    field(:result_json, :map)
    field(:status, :string)
    field(:error_json, :map)
    field(:requested_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(call, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:status])

    call
    |> cast(attrs, [
      :id,
      :session_id,
      :conversation_id,
      :workflow_run_id,
      :parent_tool_call_id,
      :tool_name,
      :tool_id,
      :args_json,
      :result_json,
      :status,
      :error_json,
      :requested_at,
      :started_at,
      :completed_at
    ])
    |> Schema.put_new_id("tool_call")
    |> Schema.normalize_strings([:status])
    |> Schema.put_json_defaults([:args_json, :result_json, :error_json])
    |> Schema.validate_status([:requested, :running, :completed, :failed, :denied, :cancelled])
    |> validate_required([:id, :tool_name, :status, :args_json, :result_json, :error_json])
  end
end
