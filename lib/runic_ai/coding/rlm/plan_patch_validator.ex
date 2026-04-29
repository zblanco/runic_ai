defmodule RunicAI.Coding.RLM.PlanPatchValidator do
  @moduledoc """
  Validation for RLM plan patches and recursive workflow expansion.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.Plan
  alias RunicAI.RLM.PlanPatch
  alias RunicAI.Coding.RLM.WorkflowValidationReport

  @spec validate(PlanPatch.t(), Plan.t() | nil, keyword()) :: WorkflowValidationReport.t()
  def validate(patch, plan \\ nil, opts \\ [])

  def validate(%PlanPatch{} = patch, plan, opts) when is_list(opts) do
    errors =
      []
      |> validate_patch_shape(patch)
      |> validate_patch_limits(patch, opts)
      |> validate_connect_to(patch, plan)

    accepted_nodes = if errors == [], do: Enum.map(patch.nodes, & &1.id), else: []
    rejected_nodes = if errors == [], do: [], else: Enum.map(patch.nodes, & &1.id)

    if errors == [] do
      WorkflowValidationReport.accept(
        accepted_nodes: accepted_nodes,
        metadata: %{patch_node_count: length(patch.nodes)}
      )
    else
      WorkflowValidationReport.reject(errors,
        accepted_nodes: accepted_nodes,
        rejected_nodes: rejected_nodes,
        metadata: %{patch_node_count: length(patch.nodes)}
      )
    end
  end

  def validate(other, _plan, _opts) do
    WorkflowValidationReport.reject([
      Error.validation("expected an RLM PlanPatch",
        source: __MODULE__,
        details: %{patch: other}
      )
    ])
  end

  defp validate_patch_shape(errors, %PlanPatch{} = patch) do
    case PlanPatch.validate(patch) do
      {:ok, _patch} -> errors
      {:error, error} -> [error | errors]
    end
  end

  defp validate_patch_limits(errors, %PlanPatch{} = patch, opts) do
    child_count = Enum.count(patch.nodes, &(&1.op == :child_workflow))

    errors
    |> reject_if_over(
      :max_patch_nodes,
      length(patch.nodes),
      Keyword.get(opts, :max_patch_nodes, 8)
    )
    |> reject_if_over(
      :max_child_workflows,
      child_count,
      Keyword.get(opts, :max_child_workflows, 2)
    )
    |> reject_if_over(
      :max_depth,
      Map.get(patch.metadata, :depth, Map.get(patch.metadata, "depth", 0)),
      Keyword.get(opts, :max_depth, 3)
    )
    |> reject_if_over(
      :max_plan_patches,
      Map.get(patch.metadata, :patch_count, Map.get(patch.metadata, "patch_count", 0)),
      Keyword.get(opts, :max_plan_patches, 4)
    )
  end

  defp validate_connect_to(errors, %PlanPatch{} = patch, nil) do
    if patch.connect_to == [], do: errors, else: errors
  end

  defp validate_connect_to(errors, %PlanPatch{} = patch, %Plan{} = plan) do
    node_ids = MapSet.new(Enum.map(plan.nodes, & &1.id))

    missing = Enum.reject(patch.connect_to, &MapSet.member?(node_ids, &1))

    case missing do
      [] ->
        errors

      _ ->
        [
          Error.validation("plan patch connects to unknown plan nodes",
            source: __MODULE__,
            details: %{missing_node_ids: missing}
          )
          | errors
        ]
    end
  end

  defp reject_if_over(errors, _key, _value, nil), do: errors

  defp reject_if_over(errors, _key, value, max) when value <= max, do: errors

  defp reject_if_over(errors, key, value, max) do
    [
      Error.validation("plan patch exceeds #{key}",
        source: __MODULE__,
        details: %{key: key, value: value, max: max}
      )
      | errors
    ]
  end
end
