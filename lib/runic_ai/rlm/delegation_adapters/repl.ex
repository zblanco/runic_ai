defmodule RunicAI.RLM.DelegationAdapters.REPL do
  @moduledoc """
  Executes explicit sandbox-REPL `SubagentAssignment` values.

  This adapter is intentionally gated. A parent coordinator must provide an
  existing sandbox session id, symbolic context handle, recursion depth limit,
  and recursive subquery budget before code can run inside the REPL runtime.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Decomposition.Result
  alias RunicAI.Error
  alias RunicAI.RLM.REPL.PythonRuntime
  alias RunicAI.RLM.REPL.State
  alias RunicAI.RLM.SubagentAssignment

  @spec run(Workspace.t(), SubagentAssignment.t() | map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(workspace, assignment, opts \\ [])

  def run(%Workspace{} = workspace, assignment, opts) when is_list(opts) do
    with {:ok, assignment} <- normalize_assignment(assignment),
         :ok <- require_repl_assignment(assignment),
         {:ok, gates} <- gates(assignment, opts),
         {:ok, registry} <- registry(opts),
         {:ok, code} <- code(assignment, opts),
         {:ok, state} <- state(assignment, gates, opts),
         {:ok, turn_result} <-
           PythonRuntime.execute_turn(state, code, registry, runtime_opts(assignment, opts)) do
      {:ok,
       %{
         assignment: assignment,
         gates: Map.drop(gates, [:sandbox_session_id]),
         repl_state: turn_result.state,
         turn_result: turn_result,
         child_result: child_result(workspace, assignment, turn_result)
       }}
    end
  end

  def run(%Workspace{} = _workspace, assignment, _opts) do
    {:error,
     Error.validation("REPL delegation adapter requires a SubagentAssignment",
       source: __MODULE__,
       details: %{assignment: assignment}
     )}
  end

  defp normalize_assignment(%SubagentAssignment{} = assignment),
    do: SubagentAssignment.validate(assignment)

  defp normalize_assignment(input) when is_map(input) or is_list(input),
    do: SubagentAssignment.new(input)

  defp require_repl_assignment(%SubagentAssignment{
         agent_kind: :workflow,
         strategy: :sandbox_repl
       }),
       do: :ok

  defp require_repl_assignment(%SubagentAssignment{} = assignment) do
    {:error,
     Error.validation("REPL delegation adapter requires a sandbox_repl workflow assignment",
       source: __MODULE__,
       details: %{agent_kind: assignment.agent_kind, strategy: assignment.strategy}
     )}
  end

  defp gates(%SubagentAssignment{} = assignment, opts) do
    with {:ok, sandbox_session_id} <- sandbox_session_id(assignment, opts),
         {:ok, symbolic_context_handle} <- symbolic_context_handle(assignment, opts),
         {:ok, max_depth} <- max_depth(assignment, opts),
         {:ok, subquery_budget} <- subquery_budget(assignment, opts),
         :ok <- validate_depth(assignment, max_depth) do
      {:ok,
       %{
         sandbox_session_id: sandbox_session_id,
         symbolic_context_handle: symbolic_context_handle,
         max_depth: max_depth,
         parent_depth: parent_depth(assignment),
         subquery_budget: subquery_budget
       }}
    end
  end

  defp sandbox_session_id(%SubagentAssignment{} = assignment, opts) do
    opts
    |> Keyword.get(:sandbox_session_id)
    |> fallback(metadata_get(assignment, :sandbox_session_id))
    |> required_string(:sandbox_session_id)
  end

  defp symbolic_context_handle(%SubagentAssignment{} = assignment, opts) do
    opts
    |> Keyword.get(:symbolic_context_handle)
    |> fallback(metadata_get(assignment, :symbolic_context_handle))
    |> fallback(metadata_get(assignment, :context_handle))
    |> required_string(:symbolic_context_handle)
  end

  defp max_depth(%SubagentAssignment{} = assignment, opts) do
    opts
    |> Keyword.get(:max_depth)
    |> fallback(metadata_get(assignment, :max_depth))
    |> fallback(budget_get(assignment, :max_depth))
    |> required_non_negative_integer(:max_depth)
  end

  defp subquery_budget(%SubagentAssignment{} = assignment, opts) do
    opts
    |> Keyword.get(:subquery_budget)
    |> fallback(metadata_get(assignment, :subquery_budget))
    |> fallback(budget_get(assignment, :rlm_queries))
    |> fallback(budget_get(assignment, :subqueries))
    |> required_non_negative_integer(:subquery_budget)
  end

  defp validate_depth(%SubagentAssignment{} = assignment, max_depth) do
    depth = parent_depth(assignment)

    if depth < max_depth do
      :ok
    else
      {:error,
       Error.validation("REPL delegation depth limit exceeded",
         source: __MODULE__,
         details: %{parent_depth: depth, max_depth: max_depth}
       )}
    end
  end

  defp registry(opts) do
    case Keyword.get(opts, :registry) do
      nil ->
        {:error,
         Error.validation("REPL delegation requires a sandbox session registry",
           source: __MODULE__,
           details: %{required_opt: :registry}
         )}

      registry ->
        {:ok, registry}
    end
  end

  defp code(%SubagentAssignment{} = assignment, opts) do
    opts
    |> Keyword.get(:code)
    |> fallback(metadata_get(assignment, :code))
    |> required_string(:code)
  end

  defp state(%SubagentAssignment{} = assignment, gates, opts) do
    case Keyword.get(opts, :state) || metadata_get(assignment, :repl_state) do
      %State{} = state ->
        with {:ok, state} <- State.validate(state),
             :ok <- validate_state_gates(state, gates) do
          {:ok, state}
        end

      nil ->
        State.new(gates.sandbox_session_id,
          id: state_id(assignment),
          runtime: runtime(assignment, opts),
          context_ref: gates.symbolic_context_handle,
          variables: variables(assignment, gates, opts),
          budgets: repl_budgets(assignment, gates),
          metadata: state_metadata(assignment, gates)
        )

      state ->
        {:error,
         Error.validation("REPL delegation state must be a RunicAI.RLM.REPL.State",
           source: __MODULE__,
           details: %{state: state}
         )}
    end
  end

  defp validate_state_gates(%State{} = state, gates) do
    cond do
      state.sandbox_session_id != gates.sandbox_session_id ->
        {:error,
         Error.validation("REPL delegation state sandbox_session_id does not match gates",
           source: __MODULE__,
           details: %{
             state_sandbox_session_id: state.sandbox_session_id,
             sandbox_session_id: gates.sandbox_session_id
           }
         )}

      state.context_ref != gates.symbolic_context_handle ->
        {:error,
         Error.validation(
           "REPL delegation state context_ref does not match symbolic context handle",
           source: __MODULE__,
           details: %{
             state_context_ref: state.context_ref,
             symbolic_context_handle: gates.symbolic_context_handle
           }
         )}

      true ->
        :ok
    end
  end

  defp runtime(%SubagentAssignment{} = assignment, opts) do
    Keyword.get(opts, :runtime) ||
      metadata_get(assignment, :runtime) ||
      :python
  end

  defp variables(%SubagentAssignment{} = assignment, gates, opts) do
    base =
      opts
      |> Keyword.get(:variables)
      |> fallback(metadata_get(assignment, :variables))
      |> case do
        variables when is_map(variables) -> variables
        _other -> %{}
      end

    Map.put_new(base, gates.symbolic_context_handle, context_variable(assignment))
  end

  defp context_variable(%SubagentAssignment{context_slice: nil}), do: nil

  defp context_variable(%SubagentAssignment{} = assignment) do
    %{
      value: assignment.context_slice,
      kind: :context_slice,
      metadata: %{source: __MODULE__}
    }
  end

  defp repl_budgets(%SubagentAssignment{} = assignment, gates) do
    assignment.budgets
    |> Map.put(:rlm_queries, gates.subquery_budget)
    |> Map.put_new(:llm_queries, budget_get(assignment, :llm_queries) || 0)
  end

  defp state_metadata(%SubagentAssignment{} = assignment, gates) do
    %{
      assignment_id: assignment.id,
      parent: assignment.parent,
      max_depth: gates.max_depth,
      parent_depth: gates.parent_depth,
      symbolic_context_handle: gates.symbolic_context_handle
    }
  end

  defp state_id(%SubagentAssignment{} = assignment), do: "repl:#{assignment.id}"

  defp runtime_opts(%SubagentAssignment{} = assignment, opts) do
    [
      timeout_ms: Keyword.get(opts, :timeout_ms, budget_get(assignment, :timeout_ms)),
      max_output_bytes:
        Keyword.get(opts, :max_output_bytes, budget_get(assignment, :max_output_bytes)),
      max_observation_bytes:
        Keyword.get(
          opts,
          :max_observation_bytes,
          budget_get(assignment, :max_observation_bytes) || 4_096
        ),
      final_schema: final_schema(assignment, opts)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp final_schema(%SubagentAssignment{} = assignment, opts) do
    Keyword.get(opts, :final_schema) ||
      metadata_get(assignment, :final_schema) ||
      non_empty_schema(assignment.output_schema)
  end

  defp non_empty_schema(schema) when schema == %{}, do: nil
  defp non_empty_schema(schema), do: schema

  defp child_result(%Workspace{} = _workspace, %SubagentAssignment{} = assignment, turn_result) do
    observation = turn_result.observation
    output = %{claims: claims(turn_result)}

    metadata = %{
      role: assignment.role,
      context_slice_id: assignment.context_slice && assignment.context_slice.id,
      observation: observation,
      repl_state_id: turn_result.state.id,
      sandbox_session_id: turn_result.state.sandbox_session_id
    }

    if successful_observation?(observation) do
      Result.completed!(assignment.id, output, metadata: metadata)
    else
      Result.failed!(assignment.id, :repl_delegate_failed, metadata: metadata)
    end
  end

  defp successful_observation?(observation) do
    Map.get(observation, :status) in [:ok, "ok", :completed, "completed"] and
      Map.get(observation, :exit_status, 0) == 0
  end

  defp claims(%{final_result: final_result}) when not is_nil(final_result) do
    case final_result do
      %{"claims" => claims} when is_list(claims) ->
        claims

      %{claims: claims} when is_list(claims) ->
        claims

      result when is_map(result) ->
        [
          %{
            claim:
              Map.get(result, "summary") || Map.get(result, :summary) ||
                Map.get(result, "answer") || Map.get(result, :answer) ||
                inspect(result, limit: 20),
            evidence_refs:
              List.wrap(Map.get(result, "evidence_refs") || Map.get(result, :evidence_refs) || []),
            confidence: Map.get(result, "confidence") || Map.get(result, :confidence)
          }
        ]

      result ->
        [%{claim: to_string(result), evidence_refs: []}]
    end
    |> Enum.map(&compact_claim/1)
  end

  defp claims(%{observation: observation}) do
    observation
    |> Map.get(:stdout_preview, "")
    |> case do
      "" -> []
      stdout -> [%{claim: stdout, evidence_refs: []}]
    end
  end

  defp compact_claim(claim) when is_map(claim) do
    claim
    |> Enum.reject(fn {_key, value} -> value in [nil, [], ""] end)
    |> Map.new()
  end

  defp parent_depth(%SubagentAssignment{parent: %{depth: depth}}) when is_integer(depth),
    do: depth

  defp parent_depth(%SubagentAssignment{}), do: 0

  defp metadata_get(%SubagentAssignment{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))
  end

  defp budget_get(%SubagentAssignment{budgets: budgets}, key) when is_map(budgets) do
    Map.get(budgets, key, Map.get(budgets, Atom.to_string(key)))
  end

  defp fallback(nil, fallback), do: fallback
  defp fallback(value, _fallback), do: value

  defp required_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}

  defp required_string(value, field) do
    {:error,
     Error.validation("REPL delegation requires #{field}",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp required_non_negative_integer(value, _field) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp required_non_negative_integer(value, field) do
    {:error,
     Error.validation("REPL delegation requires #{field} as a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
