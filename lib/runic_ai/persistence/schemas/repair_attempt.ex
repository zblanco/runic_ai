defmodule RunicAI.Persistence.Schemas.RepairAttempt do
  @moduledoc """
  Persisted RLM or harness repair attempt.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  schema "repair_attempts" do
    field(:run_id, :string)
    field(:sequence, :integer)
    field(:strategy, :string)
    field(:reason_json, :map)
    field(:diagnostics_json, :map)
    field(:proposal_before_json, :map)
    field(:proposal_after_json, :map)
    field(:status, :string)
    field(:created_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(attempt, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:strategy, :status])

    attempt
    |> cast(attrs, [
      :run_id,
      :sequence,
      :strategy,
      :reason_json,
      :diagnostics_json,
      :proposal_before_json,
      :proposal_after_json,
      :status,
      :created_at
    ])
    |> Schema.normalize_strings([:strategy, :status])
    |> Schema.put_json_defaults([
      :reason_json,
      :diagnostics_json,
      :proposal_before_json,
      :proposal_after_json
    ])
    |> Schema.validate_status([
      :pending,
      :running,
      :ok,
      :completed,
      :failed,
      :error,
      :blocked,
      :repaired,
      :satisfied,
      :exhausted,
      :timeout
    ])
    |> validate_required([
      :run_id,
      :sequence,
      :strategy,
      :reason_json,
      :diagnostics_json,
      :proposal_before_json,
      :proposal_after_json,
      :status,
      :created_at
    ])
  end
end
