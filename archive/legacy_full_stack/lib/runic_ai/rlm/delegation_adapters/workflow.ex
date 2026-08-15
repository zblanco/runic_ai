defmodule RunicAI.RLM.DelegationAdapters.Workflow do
  @moduledoc """
  Executes workflow-shaped `SubagentAssignment` values.

  Lambda assignments are converted into validated `RunicAI.RLM.LambdaPlan`
  records. Generated-component or explicit workflow assignments run through the
  assistant/RLM `WorkflowCompiler` when a blueprint is supplied, or through an
  injected runner with the same constrained assignment context.
  """

  alias RunicAI.Assistant.RLM.WorkflowCompiler
  alias RunicAI.Coding.Workspace
  alias RunicAI.Decomposition.Result
  alias RunicAI.Error
  alias RunicAI.RLM
  alias RunicAI.RLM.ContextSliceContract
  alias RunicAI.RLM.LambdaPlan
  alias RunicAI.RLM.SubagentAssignment
  alias RunicAI.RLM.TaskKind

  @workflow_strategies [:lambda_workflow, :generated_sandbox_component]
  @lambda_fallback_strategies [
    :direct_standard_agent,
    :subagent_delegation,
    :generated_sandbox_component,
    :sandbox_repl,
    :host_edit_workflow
  ]

  @spec run(Workspace.t(), SubagentAssignment.t() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(workspace, assignment, opts \\ [])

  def run(%Workspace{} = workspace, assignment, opts) when is_list(opts) do
    with {:ok, assignment} <- normalize_assignment(assignment),
         :ok <- require_workflow_assignment(assignment),
         {:ok, workflow_result} <- execute_assignment(workspace, assignment, opts) do
      {:ok,
       %{
         assignment: assignment,
         workflow_result: workflow_result,
         child_result: child_result(assignment, workflow_result)
       }}
    end
  end

  def run(%Workspace{} = _workspace, assignment, _opts) do
    {:error,
     Error.validation("workflow delegation adapter requires a SubagentAssignment",
       source: __MODULE__,
       details: %{assignment: assignment}
     )}
  end

  defp normalize_assignment(%SubagentAssignment{} = assignment),
    do: SubagentAssignment.validate(assignment)

  defp normalize_assignment(input) when is_map(input) or is_list(input),
    do: SubagentAssignment.new(input)

  defp require_workflow_assignment(%SubagentAssignment{agent_kind: :workflow, strategy: strategy})
       when strategy in @workflow_strategies,
       do: :ok

  defp require_workflow_assignment(%SubagentAssignment{} = assignment) do
    {:error,
     Error.validation("workflow delegation adapter requires workflow assignment strategy",
       source: __MODULE__,
       details: %{
         agent_kind: assignment.agent_kind,
         strategy: assignment.strategy,
         valid_strategies: @workflow_strategies
       }
     )}
  end

  defp execute_assignment(
         %Workspace{} = _workspace,
         %SubagentAssignment{strategy: :lambda_workflow} = assignment,
         opts
       ) do
    context_slice = assignment.context_slice

    with %ContextSliceContract{} <- context_slice || missing_context_slice(),
         {:ok, task_kind} <- task_kind(assignment, opts),
         {:ok, lambda_plan} <-
           RLM.lambda_plan(assignment.objective, task_kind, [context_slice.source_ref],
             context_contracts: [context_slice],
             budgets: assignment.budgets,
             fallback_strategy: fallback_strategy(assignment),
             metadata: Map.merge(assignment.metadata, %{assignment_id: assignment.id})
           ) do
      {:ok,
       %{
         status: :completed,
         kind: :lambda_plan,
         lambda_plan: lambda_plan,
         summary: "Lambda workflow plan prepared for #{assignment.id}",
         source_refs: [context_slice.source_ref.source_id],
         metadata: %{operators: LambdaPlan.operator_names(lambda_plan)}
       }}
    else
      :missing_context_slice ->
        {:error,
         Error.validation("lambda workflow delegation requires a context_slice",
           source: __MODULE__,
           details: %{assignment_id: assignment.id}
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp execute_assignment(%Workspace{} = workspace, %SubagentAssignment{} = assignment, opts) do
    cond do
      runner = Keyword.get(opts, :runner) ->
        run_injected(runner, assignment, workspace, opts)

      blueprint = blueprint(assignment, opts) ->
        run_blueprint(blueprint, assignment, workspace, opts)

      true ->
        {:error,
         Error.validation("workflow delegation requires a runner or workflow blueprint",
           source: __MODULE__,
           details: %{assignment_id: assignment.id, strategy: assignment.strategy}
         )}
    end
  end

  defp missing_context_slice, do: :missing_context_slice

  defp task_kind(%SubagentAssignment{} = assignment, opts) do
    value =
      Keyword.get(opts, :task_kind) ||
        Map.get(assignment.metadata, :task_kind) ||
        Map.get(assignment.metadata, "task_kind") ||
        :analysis

    cond do
      value in TaskKind.valid_kinds() ->
        {:ok, value}

      is_binary(value) ->
        TaskKind.valid_kinds()
        |> Enum.find(&(Atom.to_string(&1) == value))
        |> case do
          nil -> invalid_task_kind(value)
          value -> {:ok, value}
        end

      true ->
        invalid_task_kind(value)
    end
  end

  defp invalid_task_kind(value) do
    {:error,
     Error.validation("invalid workflow delegation task kind",
       source: __MODULE__,
       details: %{task_kind: value, valid_kinds: TaskKind.valid_kinds()}
     )}
  end

  defp fallback_strategy(%SubagentAssignment{parent: %{fallback: fallback}})
       when fallback in @lambda_fallback_strategies,
       do: fallback

  defp fallback_strategy(%SubagentAssignment{}), do: :subagent_delegation

  defp run_injected(runner, %SubagentAssignment{} = assignment, %Workspace{} = workspace, opts)
       when is_function(runner, 3) do
    case runner.(assignment, workflow_context(assignment, workspace, opts), opts) do
      {:ok, result} when is_map(result) ->
        {:ok, normalize_workflow_result(result)}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__)}

      result when is_map(result) ->
        {:ok, normalize_workflow_result(result)}

      other ->
        {:error,
         Error.validation("workflow runner returned invalid result",
           source: __MODULE__,
           details: %{result: other}
         )}
    end
  end

  defp run_injected(_runner, _assignment, _workspace, _opts) do
    {:error,
     Error.validation("workflow runner must be a function of arity 3", source: __MODULE__)}
  end

  defp run_blueprint(
         blueprint,
         %SubagentAssignment{} = assignment,
         %Workspace{} = workspace,
         opts
       ) do
    input = Map.get(assignment.metadata, :input, Map.get(assignment.metadata, "input", %{}))

    case WorkflowCompiler.run(blueprint, workspace, input, Keyword.get(opts, :workflow_opts, [])) do
      {:ok, result} ->
        {:ok,
         normalize_workflow_result(%{
           status: :completed,
           kind: :workflow_blueprint,
           summary: workflow_summary(result),
           output: result.output,
           artifacts: result.artifacts,
           workflow_result: result
         })}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp workflow_context(%SubagentAssignment{} = assignment, %Workspace{} = workspace, opts) do
    %{
      workspace: workspace,
      context_slice: assignment.context_slice,
      capability_profile: assignment.capability_profile,
      visible_tools: assignment.visible_tools,
      budgets: assignment.budgets,
      parent: assignment.parent,
      opts: opts
    }
  end

  defp blueprint(%SubagentAssignment{} = assignment, opts) do
    Keyword.get(opts, :blueprint) ||
      Map.get(assignment.metadata, :blueprint) ||
      Map.get(assignment.metadata, "blueprint")
  end

  defp normalize_workflow_result(result) when is_map(result) do
    result
    |> Map.put_new(:status, :completed)
    |> Map.put_new(:summary, Map.get(result, :output, ""))
  end

  defp child_result(%SubagentAssignment{} = assignment, workflow_result) do
    output = %{
      claims: claims(workflow_result)
    }

    metadata =
      %{
        role: assignment.role,
        context_slice_id: assignment.context_slice && assignment.context_slice.id,
        workflow_result: workflow_result
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Map.get(workflow_result, :status, :completed) do
      status when status in [:completed, "completed", :ok, "ok"] ->
        Result.completed!(assignment.id, output, metadata: metadata)

      status when status in [:failed, "failed", :error, "error"] ->
        Result.failed!(assignment.id, :workflow_delegate_failed,
          metadata: Map.put(metadata, :workflow_status, status)
        )

      status ->
        Result.cancelled!(assignment.id,
          output: output,
          metadata: Map.put(metadata, :workflow_status, status)
        )
    end
  end

  defp claims(%{claims: claims}) when is_list(claims), do: claims
  defp claims(%{"claims" => claims}) when is_list(claims), do: claims

  defp claims(workflow_result) do
    summary = Map.get(workflow_result, :summary, "")
    source_refs = List.wrap(Map.get(workflow_result, :source_refs, []))
    artifact_refs = List.wrap(Map.get(workflow_result, :artifact_refs, []))
    evidence_refs = Enum.uniq(source_refs ++ artifact_refs)

    claim =
      %{
        claim: summary,
        evidence_refs: evidence_refs,
        confidence: Map.get(workflow_result, :confidence)
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, [], ""] end)
      |> Map.new()

    if map_size(claim) == 0, do: [], else: [claim]
  end

  defp workflow_summary(%{output: output}) when is_binary(output), do: output
  defp workflow_summary(%{output: output}) when is_map(output), do: inspect(output, limit: 20)
  defp workflow_summary(_result), do: "workflow delegation completed"
end
