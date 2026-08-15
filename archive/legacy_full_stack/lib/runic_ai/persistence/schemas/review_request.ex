defmodule RunicAI.Persistence.Schemas.ReviewRequest do
  @moduledoc """
  Durable human-review gate record.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "review_requests" do
    field(:session_id, :string)
    field(:workflow_run_id, :string)
    field(:tool_call_id, :string)
    field(:kind, :string)
    field(:checkpoint, :string)
    field(:resume_key, :string)
    field(:status, :string)
    field(:details_json, :map)
    field(:decision_json, :map)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(request, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:kind, :status])

    request
    |> cast(attrs, [
      :id,
      :session_id,
      :workflow_run_id,
      :tool_call_id,
      :kind,
      :checkpoint,
      :resume_key,
      :status,
      :details_json,
      :decision_json
    ])
    |> Schema.put_new_id("review")
    |> Schema.normalize_strings([:kind, :status])
    |> Schema.put_json_defaults([:details_json, :decision_json])
    |> Schema.validate_status([:pending, :approved, :denied, :resolved, :cancelled, :waiting])
    |> validate_required([:id, :kind, :status, :details_json, :decision_json])
  end
end
