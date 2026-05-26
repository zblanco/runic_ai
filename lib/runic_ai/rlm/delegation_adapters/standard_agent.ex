defmodule RunicAI.RLM.DelegationAdapters.StandardAgent do
  @moduledoc """
  Executes a `SubagentAssignment` through the existing standard-agent delegate boundary.

  The adapter preserves the RunicAI tool/capability contract by using
  `RunicAI.Coding.Tools.delegate_task/4` instead of directly spawning arbitrary
  child work. The default runner can invoke the standard coding agent, while
  tests and higher-level coordinators can inject a runner with the same
  delegate callback shape.
  """

  alias RunicAI.Coding.Agent, as: CodingAgent
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Decomposition.Result
  alias RunicAI.Error
  alias RunicAI.RLM.SubagentAssignment

  @spec run(Workspace.t(), SubagentAssignment.t() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(workspace, assignment, opts \\ [])

  def run(%Workspace{} = workspace, assignment, opts) when is_list(opts) do
    with {:ok, assignment} <- normalize_assignment(assignment),
         :ok <- require_standard_assignment(assignment),
         {:ok, delegated} <-
           Tools.delegate_task(
             workspace,
             delegate_args(assignment, opts),
             [runner: Keyword.get(opts, :runner, &run_standard_agent/3)],
             Keyword.get(opts, :session_store)
           ) do
      {:ok,
       %{
         assignment: assignment,
         delegate_result: delegated,
         child_result: child_result(assignment, delegated)
       }}
    end
  end

  def run(%Workspace{} = _workspace, assignment, _opts) do
    {:error,
     Error.validation("standard delegation adapter requires a SubagentAssignment",
       source: __MODULE__,
       details: %{assignment: assignment}
     )}
  end

  defp normalize_assignment(%SubagentAssignment{} = assignment),
    do: SubagentAssignment.validate(assignment)

  defp normalize_assignment(input) when is_map(input) or is_list(input),
    do: SubagentAssignment.new(input)

  defp require_standard_assignment(%SubagentAssignment{agent_kind: :standard}), do: :ok

  defp require_standard_assignment(%SubagentAssignment{} = assignment) do
    {:error,
     Error.validation("standard delegation adapter requires agent_kind :standard",
       source: __MODULE__,
       details: %{agent_kind: assignment.agent_kind, assignment_id: assignment.id}
     )}
  end

  defp delegate_args(%SubagentAssignment{} = assignment, opts) do
    parent = assignment.parent || %{}
    context_slice = assignment.context_slice

    %{
      objective: assignment.objective,
      agent_kind: "standard",
      profile: profile(assignment),
      subagent_id: assignment.id,
      run_id: Map.get(parent, :run_id),
      session_id: Keyword.get(opts, :session_id),
      visible_tools: assignment.visible_tools,
      output_schema: assignment.output_schema,
      review_policy: assignment.review_policy || %{},
      context_slice_id: context_slice && context_slice.id,
      context_source_ref: context_slice && context_slice.source_ref.source_id,
      context_source_kind: context_slice && context_slice.source_kind,
      context_metadata: context_slice && context_slice.metadata,
      parent_strategy: Map.get(parent, :strategy),
      parent_depth: Map.get(parent, :depth),
      parent_fallback: Map.get(parent, :fallback)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp profile(%SubagentAssignment{capability_profile: nil}), do: "coding_read"

  defp profile(%SubagentAssignment{capability_profile: profile}) when is_atom(profile),
    do: Atom.to_string(profile)

  defp profile(%SubagentAssignment{capability_profile: profile}), do: profile

  defp run_standard_agent(objective, args, %{workspace: %Workspace{} = workspace}) do
    workflow =
      CodingAgent.run(workspace, objective,
        mode: :read_only,
        profile: Map.get(args, :profile),
        visible_tools: Map.get(args, :visible_tools, []),
        objective_gate?: false
      )

    summary = CodingAgent.summary(workflow)

    {:ok,
     %{
       status: :completed,
       summary: summary.reply || "",
       source_refs: List.wrap(Map.get(args, :context_source_ref)),
       artifact_refs: [],
       metadata: %{turns: summary.turns}
     }}
  end

  defp run_standard_agent(_objective, _args, _context) do
    {:error,
     Error.validation("standard delegate runner requires a workspace", source: __MODULE__)}
  end

  defp child_result(%SubagentAssignment{} = assignment, delegated) do
    output = %{claims: claims(delegated)}

    metadata =
      %{
        role: assignment.role,
        context_slice_id: assignment.context_slice && assignment.context_slice.id,
        delegate_result: delegated
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Map.get(delegated, :status, :completed) do
      status when status in [:completed, "completed", :ok, "ok"] ->
        Result.completed!(assignment.id, output, metadata: metadata)

      status when status in [:failed, "failed", :error, "error"] ->
        Result.failed!(assignment.id, :delegate_failed,
          metadata: Map.put(metadata, :delegate_status, status)
        )

      status ->
        Result.cancelled!(assignment.id,
          output: output,
          metadata: Map.put(metadata, :delegate_status, status)
        )
    end
  end

  defp claims(%{claims: claims}) when is_list(claims), do: claims
  defp claims(%{"claims" => claims}) when is_list(claims), do: claims

  defp claims(delegated) do
    claim =
      %{
        claim: Map.get(delegated, :summary, ""),
        evidence_refs:
          Enum.uniq(
            Map.get(delegated, :source_refs, []) ++ Map.get(delegated, :artifact_refs, [])
          ),
        confidence: Map.get(delegated, :confidence)
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, [], ""] end)
      |> Map.new()

    if map_size(claim) == 0, do: [], else: [claim]
  end
end
