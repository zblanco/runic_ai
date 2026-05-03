defmodule RunicAI.Coding.RLM.WorkflowValidator do
  @moduledoc """
  Policy validator for inert RLM coding workflow proposals.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.CostEstimate
  alias RunicAI.Coding.RLM.EditPatchSet
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowValidationReport

  @default_allowed_kinds [
    :llm_leaf,
    :tool,
    :deterministic_step,
    :agent,
    :verification_gate,
    :reducer,
    :review_gate,
    :workflow_patch
  ]

  @read_tools ~w(list_dir find_files read_file read_range read_many search_text search_regex extract_diagrams render_mermaid git_status git_diff git_log git_show git_branch)
  @verify_tools ~w(compile_project run_tests run_linter source_assert changed_file_inventory project_command runtime_smoke)
  @patch_tools ~w(apply_patch run_formatter)
  @allowed_commands ~w(mix git)
  @max_nodes 64

  @type opts :: keyword()

  @spec validate(WorkflowProposal.t() | map() | keyword(), opts()) ::
          WorkflowValidationReport.t()
  def validate(proposal_input, opts \\ []) when is_list(opts) do
    case WorkflowProposal.from_input(proposal_input) do
      {:ok, proposal} ->
        validate_proposal(proposal, opts)

      {:error, error} ->
        WorkflowValidationReport.reject([error])
    end
  end

  @spec validate!(WorkflowProposal.t() | map() | keyword(), opts()) ::
          WorkflowProposal.t()
  def validate!(proposal_input, opts \\ []) do
    proposal = WorkflowProposal.from_input(proposal_input) |> unwrap!()
    report = validate(proposal, opts)

    if WorkflowValidationReport.accepted?(report) do
      proposal
    else
      first_error = List.first(report.errors)
      raise ArgumentError, error_message(first_error)
    end
  end

  defp validate_proposal(%WorkflowProposal{} = proposal, opts) do
    node_ids = Enum.map(proposal.nodes, & &1.id)
    allowed_kinds = Keyword.get(opts, :allowed_kinds, @default_allowed_kinds)

    errors =
      []
      |> require_stop_conditions(proposal)
      |> require_unique_node_ids(node_ids)
      |> require_node_count(proposal.nodes, opts)
      |> reject_disallowed_kinds(proposal.nodes, allowed_kinds)
      |> reject_unknown_edges(proposal.edges, node_ids)
      |> reject_cycles(proposal, opts)
      |> reject_unsafe_nodes(proposal.nodes, opts)
      |> reject_budget_overflow(proposal, opts)

    rejected_nodes = rejected_node_ids(proposal.nodes, errors)
    accepted_nodes = node_ids -- rejected_nodes

    report_opts = [
      errors: errors,
      warnings: warnings(proposal, opts),
      accepted_nodes: accepted_nodes,
      rejected_nodes: rejected_nodes,
      estimated_cost: estimate_cost(proposal),
      metadata: %{proposal_id: proposal.id, node_count: length(proposal.nodes)}
    ]

    if errors == [] do
      WorkflowValidationReport.accept(report_opts)
    else
      WorkflowValidationReport.reject(errors, report_opts)
    end
  end

  defp require_stop_conditions(errors, %WorkflowProposal{stop_conditions: []}) do
    [
      error("workflow proposal requires at least one stop condition",
        reason: :missing_stop_condition
      )
      | errors
    ]
  end

  defp require_stop_conditions(errors, _proposal), do: errors

  defp require_unique_node_ids(errors, node_ids) do
    duplicates = node_ids -- Enum.uniq(node_ids)

    case duplicates do
      [] ->
        errors

      _ ->
        [
          error("workflow proposal node ids must be unique",
            reason: :duplicate_node_ids,
            node_ids: duplicates
          )
          | errors
        ]
    end
  end

  defp require_node_count(errors, nodes, opts) do
    max_nodes = Keyword.get(opts, :max_nodes, @max_nodes)

    if length(nodes) <= max_nodes do
      errors
    else
      [
        error("workflow proposal exceeds max node count",
          reason: :node_budget,
          node_count: length(nodes),
          max_nodes: max_nodes
        )
        | errors
      ]
    end
  end

  defp reject_disallowed_kinds(errors, nodes, allowed_kinds) do
    rejected =
      Enum.filter(nodes, fn %ProposalNode{} = node -> node.kind not in allowed_kinds end)

    case rejected do
      [] ->
        errors

      nodes ->
        [
          error("workflow proposal contains disallowed node kinds",
            reason: :disallowed_node_kind,
            node_ids: Enum.map(nodes, & &1.id),
            kinds: Enum.map(nodes, & &1.kind),
            allowed_kinds: allowed_kinds
          )
          | errors
        ]
    end
  end

  defp reject_unknown_edges(errors, edges, node_ids) do
    node_set = MapSet.new(node_ids)

    unknown =
      Enum.filter(edges, fn edge ->
        not MapSet.member?(node_set, edge.from) or not MapSet.member?(node_set, edge.to)
      end)

    case unknown do
      [] ->
        errors

      edges ->
        [
          error("workflow proposal edges reference unknown nodes",
            reason: :unknown_edge_ref,
            edges: edges
          )
          | errors
        ]
    end
  end

  defp reject_cycles(errors, proposal, opts) do
    if Keyword.get(opts, :allow_cycles?, false) and bounded_recursion?(proposal, opts) do
      errors
    else
      case cyclic?(proposal) do
        false -> errors
        true -> [error("workflow proposal graph is cyclic", reason: :cycle) | errors]
      end
    end
  end

  defp reject_unsafe_nodes(errors, nodes, opts) do
    Enum.reduce(nodes, errors, fn node, errors ->
      case unsafe_node_error(node, opts) do
        nil -> errors
        error -> [error | errors]
      end
    end)
  end

  defp unsafe_node_error(%ProposalNode{kind: :tool} = node, opts) do
    name = param(node, :tool) || param(node, :name)
    allowed_tools = allowed_tools(opts)

    cond do
      not is_binary(name) ->
        node_error(node, "tool node requires a tool name", :missing_tool_name)

      name not in allowed_tools ->
        node_error(node, "tool node uses a disallowed tool", :disallowed_tool, %{tool: name})

      true ->
        nil
    end
  end

  defp unsafe_node_error(%ProposalNode{kind: :command} = node, opts) do
    args = normalize_map(param(node, :args) || %{})
    argv = param(node, :argv) || get(args, :argv)
    command = List.first(List.wrap(argv)) || param(node, :command) || get(args, :command)
    allowed_commands = Keyword.get(opts, :allowed_commands, @allowed_commands)

    cond do
      not Keyword.get(opts, :allow_commands?, false) ->
        node_error(node, "command nodes are disabled by default", :command_disabled)

      not is_binary(command) ->
        node_error(node, "command node requires argv or command", :missing_command)

      command not in allowed_commands ->
        node_error(node, "command node uses a disallowed command", :disallowed_command, %{
          command: command
        })

      true ->
        nil
    end
  end

  defp unsafe_node_error(%ProposalNode{kind: :script} = node, opts) do
    if Keyword.get(opts, :allow_scripts?, false) do
      nil
    else
      node_error(node, "script nodes are disabled by default", :script_disabled)
    end
  end

  defp unsafe_node_error(%ProposalNode{kind: :edit} = node, opts) do
    cond do
      not Keyword.get(opts, :allow_mutation?, false) ->
        node_error(node, "edit nodes require mutation to be enabled", :edit_disabled)

      is_nil(param(node, :patch_set)) and is_nil(param(node, :operations)) ->
        node_error(node, "edit node requires patch_set or operations", :missing_edit_operations)

      true ->
        invalid_edit_node_error(node)
    end
  end

  defp unsafe_node_error(%ProposalNode{kind: :verification_gate} = node, opts) do
    contract = param(node, :contract)
    checks = param(node, :checks)

    cond do
      not Keyword.get(opts, :allow_verification?, true) ->
        node_error(
          node,
          "verification gate nodes are disabled by current policy",
          :verification_disabled
        )

      missing_verification_contract?(contract, checks) ->
        node_error(
          node,
          "verification gate requires a non-empty contract or checks",
          :missing_verification_contract
        )

      true ->
        nil
    end
  end

  defp unsafe_node_error(%ProposalNode{kind: :agent} = node, opts) do
    mode = normalize_mode(param(node, :mode) || :read_only)

    cond do
      mode in [:read_only, :explain_repo, :review, :triage_bug] ->
        nil

      mode in [:patch, :verify, :write_tests, :fix_ci] and
          Keyword.get(opts, :allow_mutation?, false) ->
        nil

      true ->
        node_error(
          node,
          "agent node mode is not allowed by current mutation policy",
          :disallowed_agent_mode,
          %{mode: mode}
        )
    end
  end

  defp unsafe_node_error(%ProposalNode{kind: :deterministic_step} = node, _opts) do
    action = param(node, :action)
    allowed = ~w(source_summary workspace_summary passthrough constant merge)

    if action in allowed do
      nil
    else
      node_error(
        node,
        "deterministic step action is not allowlisted",
        :disallowed_deterministic_step,
        %{action: action}
      )
    end
  end

  defp unsafe_node_error(_node, _opts), do: nil

  defp missing_verification_contract?(contract, checks) do
    empty_contract? =
      is_nil(contract) or contract == %{} or contract == "" or contract == []

    empty_checks? =
      is_nil(checks) or List.wrap(checks) == []

    empty_contract? and empty_checks?
  end

  defp invalid_edit_node_error(%ProposalNode{} = node) do
    patch_set =
      param(node, :patch_set) ||
        %{
          objective: param(node, :objective) || "validate edit node",
          operations: List.wrap(param(node, :operations)),
          expected_changed_files: List.wrap(param(node, :expected_changed_files)),
          target_paths: List.wrap(param(node, :target_paths)),
          metadata: param(node, :metadata) || %{}
        }

    case EditPatchSet.from_input(patch_set) do
      {:ok, _patch_set} ->
        nil

      {:error, %Error{} = error} ->
        node_error(node, error.message, :invalid_edit_operations, %{error: error.details})
    end
  end

  defp reject_budget_overflow(errors, proposal, opts) do
    leaf_count = Enum.count(proposal.nodes, &(&1.kind == :llm_leaf))
    child_count = Enum.count(proposal.nodes, &(&1.kind == :agent))
    patch_count = Enum.count(proposal.nodes, &(&1.kind == :workflow_patch))

    errors
    |> reject_if_over(:max_leaf_calls, leaf_count, opts)
    |> reject_if_over(:max_child_workflows, child_count, opts)
    |> reject_if_over(:max_plan_patches, patch_count, opts)
  end

  defp reject_if_over(errors, key, value, opts) do
    case Keyword.get(opts, key) do
      nil ->
        errors

      max when value <= max ->
        errors

      max ->
        [error("workflow proposal exceeds #{key}", reason: key, value: value, max: max) | errors]
    end
  end

  defp allowed_tools(opts) do
    cond do
      Keyword.get(opts, :allow_mutation?, false) ->
        @read_tools ++ @verify_tools ++ @patch_tools

      Keyword.get(opts, :allow_verification?, false) ->
        @read_tools ++ @verify_tools

      true ->
        Keyword.get(opts, :allowed_tools, @read_tools)
    end
  end

  defp warnings(%WorkflowProposal{} = proposal, _opts) do
    []
    |> maybe_warn(proposal.sources == [], "proposal does not name explicit source refs")
  end

  defp maybe_warn(warnings, true, warning), do: [warning | warnings]
  defp maybe_warn(warnings, false, _warning), do: warnings

  defp estimate_cost(%WorkflowProposal{} = proposal) do
    CostEstimate.new!(
      leaf_calls: Enum.count(proposal.nodes, &(&1.kind == :llm_leaf)),
      reducer_calls: Enum.count(proposal.nodes, &(&1.kind == :reducer)),
      environment_reads: Enum.count(proposal.nodes, &(&1.kind in [:tool, :llm_leaf, :agent])),
      latency_class: latency_class(length(proposal.nodes)),
      assumptions: ["coding RLM proposal estimate is node-count based"],
      metadata: %{node_count: length(proposal.nodes)}
    )
  end

  defp latency_class(count) when count <= 1, do: :single
  defp latency_class(count) when count <= 8, do: :small_parallel
  defp latency_class(_count), do: :large_parallel

  defp cyclic?(%WorkflowProposal{} = proposal) do
    children =
      proposal.edges
      |> Enum.group_by(& &1.from, & &1.to)

    Enum.any?(proposal.nodes, fn node ->
      visit_cycle?(node.id, children, MapSet.new(), MapSet.new())
    end)
  end

  defp visit_cycle?(node_id, children, visiting, visited) do
    cond do
      MapSet.member?(visiting, node_id) ->
        true

      MapSet.member?(visited, node_id) ->
        false

      true ->
        visiting = MapSet.put(visiting, node_id)
        visited = MapSet.put(visited, node_id)

        children
        |> Map.get(node_id, [])
        |> Enum.any?(&visit_cycle?(&1, children, visiting, visited))
    end
  end

  defp bounded_recursion?(%WorkflowProposal{} = proposal, opts) do
    depth =
      get_in(proposal.policies, [:recursion, :max_depth]) ||
        get_in(proposal.policies, ["recursion", "max_depth"]) || Keyword.get(opts, :max_depth)

    is_integer(depth) and depth > 0
  end

  defp rejected_node_ids(nodes, errors) do
    mentioned =
      errors
      |> Enum.flat_map(fn
        %Error{details: %{node_id: node_id}} -> [node_id]
        %Error{details: %{node_ids: node_ids}} when is_list(node_ids) -> node_ids
        _ -> []
      end)

    if mentioned == [] and errors != [] do
      Enum.map(nodes, & &1.id)
    else
      Enum.uniq(mentioned)
    end
  end

  defp node_error(%ProposalNode{} = node, message, reason, details \\ %{}) do
    error(
      message,
      Keyword.merge([reason: reason, node_id: node.id, kind: node.kind], Map.to_list(details))
    )
  end

  defp error(message, details) do
    Error.validation(message, source: __MODULE__, details: Map.new(details))
  end

  defp param(%ProposalNode{} = node, key) do
    Map.get(node.params, key) || Map.get(node.params, Atom.to_string(key))
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp normalize_mode(mode) when is_atom(mode), do: mode
  defp normalize_mode("read_only"), do: :read_only
  defp normalize_mode("explain_repo"), do: :explain_repo
  defp normalize_mode("review"), do: :review
  defp normalize_mode("triage_bug"), do: :triage_bug
  defp normalize_mode("patch"), do: :patch
  defp normalize_mode("verify"), do: :verify
  defp normalize_mode("write_tests"), do: :write_tests
  defp normalize_mode("fix_ci"), do: :fix_ci
  defp normalize_mode(mode), do: mode

  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, %Error{} = error}), do: raise(ArgumentError, error.message)

  defp error_message(%Error{} = error), do: error.message
  defp error_message(other), do: inspect(other)
end
