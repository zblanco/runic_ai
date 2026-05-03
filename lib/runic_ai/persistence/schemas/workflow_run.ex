defmodule RunicAI.Persistence.Schemas.WorkflowRun do
  @moduledoc """
  Concrete durable execution of a Runic workflow.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "workflow_runs" do
    field(:workflow_key, :string)
    field(:workflow_name, :string)
    field(:workflow_id_blob, :binary)
    field(:session_id, :string)
    field(:managed_workflow_id, :string)
    field(:status, :string)
    field(:trigger, :string)
    field(:input_blob, :binary)
    field(:metadata_json, :map)
    field(:last_event_sequence, :integer)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:failed_at, :utc_datetime_usec)
    field(:last_checkpointed_at, :utc_datetime_usec)
    field(:error_json, :map)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:status, :trigger])

    run
    |> cast(attrs, [
      :id,
      :workflow_key,
      :workflow_name,
      :workflow_id_blob,
      :session_id,
      :managed_workflow_id,
      :status,
      :trigger,
      :input_blob,
      :metadata_json,
      :last_event_sequence,
      :started_at,
      :completed_at,
      :failed_at,
      :last_checkpointed_at,
      :error_json
    ])
    |> Schema.normalize_strings([:status, :trigger])
    |> Schema.put_json_defaults([:metadata_json, :error_json])
    |> Schema.validate_status([
      :pending,
      :running,
      :completed,
      :failed,
      :blocked,
      :paused,
      :waiting,
      :review,
      :cancelled
    ])
    |> validate_required([
      :id,
      :workflow_key,
      :workflow_id_blob,
      :status,
      :metadata_json,
      :error_json
    ])
  end
end
