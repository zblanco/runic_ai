defmodule RunicAI.Persistence.Schemas.RunnableEvent do
  @moduledoc """
  Queryable Runic runnable lifecycle event.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  schema "runnable_events" do
    field(:run_id, :string)
    field(:sequence, :integer)
    field(:runnable_id, :string)
    field(:node_name, :string)
    field(:node_hash, :string)
    field(:component_id, :string)
    field(:component_type, :string)
    field(:stage, :string)
    field(:status, :string)
    field(:input_preview, :map)
    field(:output_preview, :map)
    field(:error_json, :map)
    field(:policy_json, :map)
    field(:duration_ms, :integer)
    field(:inserted_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:stage, :status])

    event
    |> cast(attrs, [
      :run_id,
      :sequence,
      :runnable_id,
      :node_name,
      :node_hash,
      :component_id,
      :component_type,
      :stage,
      :status,
      :input_preview,
      :output_preview,
      :error_json,
      :policy_json,
      :duration_ms,
      :inserted_at
    ])
    |> Schema.normalize_strings([:stage, :status])
    |> Schema.put_json_defaults([:input_preview, :output_preview, :error_json, :policy_json])
    |> Schema.validate_status([
      :pending,
      :running,
      :ok,
      :completed,
      :failed,
      :error,
      :blocked,
      :waiting,
      :review,
      :skipped
    ])
    |> validate_required([
      :run_id,
      :sequence,
      :stage,
      :status,
      :input_preview,
      :output_preview,
      :error_json,
      :policy_json,
      :inserted_at
    ])
  end
end
