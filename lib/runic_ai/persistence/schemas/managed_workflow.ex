defmodule RunicAI.Persistence.Schemas.ManagedWorkflow do
  @moduledoc """
  Stable workflow definition that can produce many concrete workflow runs.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias RunicAI.Persistence.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "managed_workflows" do
    field(:workflow_key, :string)
    field(:workflow_name, :string)
    field(:scope_type, :string)
    field(:scope_id, :string)
    field(:status, :string)
    field(:definition_kind, :string)
    field(:definition_blob, :binary)
    field(:checkpoint_strategy, :string)
    field(:restart_policy, :string)
    field(:last_run_id, :string)
    field(:latest_revision_id, :string)
    field(:review_revision_id, :string)
    field(:active_revision_id, :string)
    field(:metadata_json, :map)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(workflow, attrs) do
    attrs =
      Schema.stringify_attr_values(attrs, [
        :scope_type,
        :status,
        :definition_kind,
        :checkpoint_strategy,
        :restart_policy
      ])

    workflow
    |> cast(attrs, [
      :id,
      :workflow_key,
      :workflow_name,
      :scope_type,
      :scope_id,
      :status,
      :definition_kind,
      :definition_blob,
      :checkpoint_strategy,
      :restart_policy,
      :last_run_id,
      :latest_revision_id,
      :review_revision_id,
      :active_revision_id,
      :metadata_json
    ])
    |> Schema.put_new_id("managed_workflow")
    |> Schema.normalize_strings([
      :scope_type,
      :status,
      :definition_kind,
      :checkpoint_strategy,
      :restart_policy
    ])
    |> Schema.put_json_defaults([:metadata_json])
    |> Schema.validate_status([
      :pending,
      :active,
      :paused,
      :failed,
      :scheduled,
      :disabled,
      :archived
    ])
    |> validate_inclusion(:checkpoint_strategy, [
      "manual",
      "every_cycle",
      "on_complete",
      "every_n"
    ])
    |> validate_inclusion(:restart_policy, ["never", "on_failure", "always", "manual"])
    |> validate_required([:id, :workflow_key, :status, :definition_kind, :metadata_json])
  end
end
