defmodule RunicAI.Persistence.Schemas.Scorecard do
  @moduledoc """
  Persisted scorecard or objective gate result.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  schema "scorecards" do
    field(:run_id, :string)
    field(:component_id, :string)
    field(:objective_status, :string)
    field(:scorecard_json, :map)
    field(:created_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(scorecard, attrs) do
    attrs = Schema.stringify_attr_values(attrs, [:objective_status])

    scorecard
    |> cast(attrs, [:run_id, :component_id, :objective_status, :scorecard_json, :created_at])
    |> Schema.normalize_strings([:objective_status])
    |> Schema.put_json_defaults([:scorecard_json])
    |> validate_inclusion(:objective_status, [
      "objective_satisfied",
      "objective_incomplete",
      "blocked",
      "error",
      "unknown",
      "ok"
    ])
    |> validate_required([:run_id, :objective_status, :scorecard_json, :created_at])
  end
end
