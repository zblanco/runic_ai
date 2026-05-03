defmodule RunicAI.Persistence.Schemas.WorkflowFact do
  @moduledoc """
  Content-addressed Runic workflow fact value.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:hash_key, :string, autogenerate: false}

  schema "workflow_facts" do
    field(:run_id, :string)
    field(:producer_node, :string)
    field(:component_id, :string)
    field(:value_blob, :binary)
    field(:preview_json, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(fact, attrs) do
    fact
    |> cast(attrs, [
      :hash_key,
      :run_id,
      :producer_node,
      :component_id,
      :value_blob,
      :preview_json,
      :inserted_at
    ])
    |> Schema.put_json_defaults([:preview_json])
    |> validate_required([:hash_key, :value_blob, :preview_json, :inserted_at])
  end
end
