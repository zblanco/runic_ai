defmodule RunicAI.Workflows.Editor do
  @moduledoc """
  Pure transactional editing for workflow IR V1.

  A batch is applied to an in-memory copy, checked against its base revision and
  optional semantic hash, then draft-validated as one unit. Failed batches never
  return a partially edited workflow.
  """

  alias RunicAI.Error
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.Validator

  @type result :: %{
          required(:ir) => IR.t(),
          required(:base_revision) => pos_integer(),
          required(:result_revision) => pos_integer(),
          required(:base_hash) => String.t(),
          required(:result_hash) => String.t(),
          required(:operations) => [map()],
          required(:inverse_operations) => [map()],
          required(:affected_nodes) => [String.t()],
          required(:diff) => map(),
          required(:diagnostics) => [map()]
        }

  @spec apply(IR.t() | map(), map() | keyword()) :: {:ok, result()} | {:error, Error.t()}
  def apply(input, batch) when is_map(batch) or is_list(batch) do
    with {:ok, ir} <- IR.from_input(input),
         :ok <- check_base_revision(ir, get(batch, :base_revision)),
         :ok <- check_base_hash(ir, get(batch, :base_hash)),
         {:ok, operations} <- operation_list(get(batch, :operations, [])),
         {:ok, edited, inverses, affected} <- apply_operations(ir, operations),
         {:ok, edited} <- revise(edited, ir.revision + 1),
         report = Validator.report(edited, mode: :draft),
         :ok <- accept_report(report) do
      {:ok,
       %{
         ir: edited,
         base_revision: ir.revision,
         result_revision: edited.revision,
         base_hash: IR.semantic_hash(ir),
         result_hash: IR.semantic_hash(edited),
         operations: operations,
         inverse_operations: List.flatten(inverses),
         affected_nodes: affected |> MapSet.to_list() |> Enum.sort(),
         diff: semantic_diff(ir, edited),
         diagnostics: report.diagnostics
       }}
    end
  end

  def apply(_input, batch) do
    {:error,
     Error.validation("workflow edit batch must be a map or keyword list",
       source: __MODULE__,
       details: %{code: :invalid_operation_batch, batch: batch}
     )}
  end

  @doc "Returns a directional semantic diff between two complete workflow revisions."
  @spec diff(IR.t() | map(), IR.t() | map()) :: {:ok, map()} | {:error, Error.t()}
  def diff(before_input, updated_input) do
    with {:ok, before} <- IR.from_input(before_input),
         {:ok, updated} <- IR.from_input(updated_input) do
      {:ok, semantic_diff(before, updated)}
    end
  end

  defp apply_operations(ir, operations) do
    operations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, ir, [], MapSet.new()}, fn {operation, index},
                                                         {:ok, current, inverses, affected} ->
      case apply_operation(current, operation) do
        {:ok, updated, inverse, operation_affected} ->
          {:cont,
           {:ok, updated, [List.wrap(inverse) | inverses],
            Enum.reduce(operation_affected, affected, &MapSet.put(&2, &1))}}

        {:error, %Error{} = error} ->
          {:halt,
           {:error,
            %{
              error
              | details: Map.merge(error.details, %{operation_index: index, operation: operation})
            }}}
      end
    end)
  end

  defp apply_operation(ir, operation) do
    case operation_name(operation) do
      :add_node ->
        add_node(ir, operation)

      :replace_node ->
        replace_node(ir, operation)

      :remove_node ->
        remove_node(ir, operation)

      :connect ->
        connect(ir, operation)

      :disconnect ->
        disconnect(ir, operation)

      :set_argument ->
        set_node_map(ir, operation, :arguments, :remove_argument)

      :remove_argument ->
        remove_node_map_value(ir, operation, :arguments, :set_argument)

      :set_policy ->
        set_policy(ir, operation)

      :remove_policy ->
        remove_policy(ir, operation)

      :set_acceptance ->
        set_acceptance(ir, operation)

      :remove_acceptance ->
        remove_acceptance(ir, operation)

      :resolve_hole ->
        resolve_hole(ir, operation)

      :add_hole ->
        add_hole(ir, operation)

      :annotate ->
        annotate(ir, operation)

      :remove_annotation ->
        remove_annotation(ir, operation)

      unknown ->
        operation_error(:unknown_operation, "unknown workflow edit operation", %{op: unknown})
    end
  end

  defp add_node(ir, operation) do
    with {:ok, node} <- Node.from_input(get(operation, :node)),
         :ok <-
           ensure_absent(
             ir.nodes,
             node.id,
             :node_already_exists,
             "workflow node already exists",
             %{node_id: node.id}
           ) do
      updated = %{ir | nodes: Map.put(ir.nodes, node.id, node)}
      {:ok, updated, %{op: "remove_node", node_id: node.id, cascade: false}, [node.id]}
    end
  end

  defp replace_node(ir, operation) do
    node_id = get(operation, :node_id)

    with {:ok, existing} <- fetch_node(ir, node_id),
         {:ok, replacement} <- Node.from_input(get(operation, :node)),
         true <-
           replacement.id == node_id ||
             operation_error(:replacement_id_mismatch, "replacement node id must be stable", %{
               node_id: node_id,
               replacement_id: replacement.id
             }) do
      updated = %{ir | nodes: Map.put(ir.nodes, node_id, replacement)}
      {:ok, updated, %{op: "replace_node", node_id: node_id, node: existing}, [node_id]}
    end
  end

  defp remove_node(ir, operation) do
    node_id = get(operation, :node_id)
    cascade? = get(operation, :cascade, false) == true

    with {:ok, node} <- fetch_node(ir, node_id),
         incident = incident_edges(ir, node_id),
         :ok <- require_cascade(incident, cascade?, node_id) do
      updated = %{
        ir
        | nodes: Map.delete(ir.nodes, node_id),
          edges: Enum.reduce(incident, ir.edges, &Map.delete(&2, &1.id))
      }

      inverse =
        [%{op: "add_node", node: node}] ++
          Enum.map(incident, &%{op: "connect", edge: &1})

      affected = [node_id | Enum.flat_map(incident, &[&1.from.node, &1.to.node])]
      {:ok, updated, inverse, affected}
    end
  end

  defp connect(ir, operation) do
    with {:ok, edge} <- edge_from_operation(operation),
         :ok <-
           ensure_absent(
             ir.edges,
             edge.id,
             :edge_already_exists,
             "workflow edge already exists",
             %{edge_id: edge.id}
           ),
         candidate = %{ir | edges: Map.put(ir.edges, edge.id, edge)},
         :ok <- accept_report(Validator.report(candidate, mode: :draft)) do
      inverse = %{op: "disconnect", edge_id: edge.id}
      {:ok, candidate, inverse, [edge.from.node, edge.to.node]}
    end
  end

  defp edge_from_operation(operation) do
    case get(operation, :edge) do
      edge when is_map(edge) ->
        Edge.from_input(edge)

      _other ->
        opts =
          [
            id: get(operation, :edge_id),
            mode: get(operation, :mode, :data),
            metadata: get(operation, :metadata, %{})
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        Edge.new(get(operation, :from), get(operation, :to), opts)
    end
  end

  defp disconnect(ir, operation) do
    edge_id = get(operation, :edge_id)

    case Map.fetch(ir.edges, edge_id) do
      {:ok, edge} ->
        {:ok, %{ir | edges: Map.delete(ir.edges, edge_id)}, %{op: "connect", edge: edge},
         [edge.from.node, edge.to.node]}

      :error ->
        operation_error(:unknown_edge, "workflow edge does not exist", %{edge_id: edge_id})
    end
  end

  defp set_node_map(ir, operation, field, inverse_remove_op) do
    node_id = get(operation, :node_id)
    key = get(operation, :key)
    value = get(operation, :value)

    with :ok <- require_key(key),
         {:ok, node} <- fetch_node(ir, node_id) do
      values = Map.fetch!(node, field)
      storage_key = equivalent_key(values, key)

      {inverse_op, _prior} =
        inverse_set(values, storage_key, value, node_id, field, inverse_remove_op)

      updated_node = Map.put(node, field, Map.put(values, storage_key, value))
      {:ok, put_in(ir.nodes[node_id], updated_node), inverse_op, [node_id]}
    end
  end

  defp remove_node_map_value(ir, operation, field, inverse_set_op) do
    node_id = get(operation, :node_id)
    key = get(operation, :key)

    with :ok <- require_key(key),
         {:ok, node} <- fetch_node(ir, node_id),
         values = Map.fetch!(node, field),
         storage_key = equivalent_key(values, key),
         {:ok, prior} <- fetch_map_value(values, storage_key, field) do
      updated_node = Map.put(node, field, Map.delete(values, storage_key))

      inverse = %{
        op: Atom.to_string(inverse_set_op),
        node_id: node_id,
        key: storage_key,
        value: prior
      }

      {:ok, put_in(ir.nodes[node_id], updated_node), inverse, [node_id]}
    end
  end

  defp set_policy(ir, operation) do
    case get(operation, :node_id) do
      nil -> set_workflow_map(ir, operation, :policies, :remove_policy)
      _node_id -> set_node_map(ir, operation, :policy, :remove_policy)
    end
  end

  defp remove_policy(ir, operation) do
    case get(operation, :node_id) do
      nil -> remove_workflow_map_value(ir, operation, :policies, :set_policy)
      _node_id -> remove_node_map_value(ir, operation, :policy, :set_policy)
    end
  end

  defp set_workflow_map(ir, operation, field, inverse_remove_op) do
    key = get(operation, :key)
    value = get(operation, :value)

    with :ok <- require_key(key) do
      values = Map.fetch!(ir, field)
      storage_key = equivalent_key(values, key)
      {inverse, _prior} = inverse_set(values, storage_key, value, nil, field, inverse_remove_op)
      {:ok, Map.put(ir, field, Map.put(values, storage_key, value)), inverse, []}
    end
  end

  defp remove_workflow_map_value(ir, operation, field, inverse_set_op) do
    key = get(operation, :key)

    with :ok <- require_key(key),
         values = Map.fetch!(ir, field),
         storage_key = equivalent_key(values, key),
         {:ok, prior} <- fetch_map_value(values, storage_key, field) do
      inverse = %{op: Atom.to_string(inverse_set_op), key: storage_key, value: prior}
      {:ok, Map.put(ir, field, Map.delete(values, storage_key)), inverse, []}
    end
  end

  defp set_acceptance(ir, operation) do
    check = get(operation, :check) || get(operation, :acceptance)
    id = get(operation, :acceptance_id) || get(check || %{}, :id)
    existing = Enum.find(ir.acceptance, &(get(&1, :id) == id))

    with true <-
           is_map(check) || operation_error(:invalid_acceptance, "acceptance must be a map", %{}),
         true <-
           (is_binary(id) and id != "") ||
             operation_error(:invalid_acceptance, "acceptance id must be non-empty", %{id: id}),
         :ok <- validate_acceptance_replacement(existing, check, id) do
      check = put_field(check, :id, id)
      {prior, others} = Enum.split_with(ir.acceptance, &(get(&1, :id) == id))

      inverse =
        case prior do
          [existing | _] -> %{op: "set_acceptance", acceptance_id: id, check: existing}
          [] -> %{op: "remove_acceptance", acceptance_id: id}
        end

      {:ok, %{ir | acceptance: others ++ [check]}, inverse, []}
    end
  end

  defp validate_acceptance_replacement(nil, _check, _id), do: :ok

  defp validate_acceptance_replacement(existing, check, id) do
    existing_kind = get(existing, :kind)
    replacement_kind = get(check, :kind)

    cond do
      not is_nil(existing_kind) and is_nil(replacement_kind) ->
        operation_error(
          :incomplete_acceptance_replacement,
          "replacement acceptance must preserve its kind",
          %{acceptance_id: id, expected_kind: existing_kind}
        )

      existing_kind in [:declared_stop_condition, "declared_stop_condition"] and
          is_nil(get(check, :condition)) ->
        operation_error(
          :incomplete_acceptance_replacement,
          "declared stop-condition replacement must include condition",
          %{acceptance_id: id, expected_field: :condition}
        )

      true ->
        :ok
    end
  end

  defp remove_acceptance(ir, operation) do
    id = get(operation, :acceptance_id)
    {matched, remaining} = Enum.split_with(ir.acceptance, &(get(&1, :id) == id))

    case matched do
      [existing | _] ->
        {:ok, %{ir | acceptance: remaining},
         %{op: "set_acceptance", acceptance_id: id, check: existing}, []}

      [] ->
        operation_error(:unknown_acceptance, "workflow acceptance does not exist", %{
          acceptance_id: id
        })
    end
  end

  defp resolve_hole(ir, operation) do
    id = get(operation, :hole_id)
    {matched, remaining} = Enum.split_with(ir.holes, &(get(&1, :id) == id))

    case matched do
      [hole | _] -> {:ok, %{ir | holes: remaining}, %{op: "add_hole", hole: hole}, []}
      [] -> operation_error(:unknown_hole, "workflow hole does not exist", %{hole_id: id})
    end
  end

  defp add_hole(ir, operation) do
    hole = get(operation, :hole)
    id = get(hole || %{}, :id)

    if is_map(hole) and is_binary(id) and id != "" do
      {:ok, %{ir | holes: ir.holes ++ [hole]}, %{op: "resolve_hole", hole_id: id}, []}
    else
      operation_error(:invalid_hole, "workflow hole requires a non-empty id", %{hole: hole})
    end
  end

  defp annotate(ir, operation) do
    case get(operation, :node_id) do
      nil -> set_workflow_map(ir, operation, :metadata, :remove_annotation)
      _node_id -> set_node_map(ir, operation, :metadata, :remove_annotation)
    end
  end

  defp remove_annotation(ir, operation) do
    case get(operation, :node_id) do
      nil -> remove_workflow_map_value(ir, operation, :metadata, :annotate)
      _node_id -> remove_node_map_value(ir, operation, :metadata, :annotate)
    end
  end

  defp inverse_set(values, key, value, node_id, _field, remove_op) do
    inverse =
      case Map.fetch(values, key) do
        {:ok, prior} ->
          %{op: inverse_set_name(remove_op), node_id: node_id, key: key, value: prior}

        :error ->
          %{op: Atom.to_string(remove_op), node_id: node_id, key: key}
      end
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {inverse, value}
  end

  defp inverse_set_name(:remove_argument), do: "set_argument"
  defp inverse_set_name(:remove_policy), do: "set_policy"
  defp inverse_set_name(:remove_annotation), do: "annotate"

  defp semantic_diff(before, updated) do
    %{
      revision: %{from: before.revision, to: updated.revision},
      nodes: map_diff(before.nodes, updated.nodes),
      edges: map_diff(before.edges, updated.edges),
      acceptance: id_list_diff(before.acceptance, updated.acceptance),
      holes: id_list_diff(before.holes, updated.holes),
      workflow_policy: value_diff(before.policies, updated.policies),
      workflow_metadata: value_diff(before.metadata, updated.metadata),
      workflow_policy_changed?: before.policies != updated.policies,
      workflow_metadata_changed?: before.metadata != updated.metadata
    }
  end

  defp value_diff(before, updated) do
    %{
      changed?: before != updated,
      before: before,
      after: updated
    }
  end

  defp map_diff(before, updated) do
    before_keys = Map.keys(before) |> MapSet.new()
    updated_keys = Map.keys(updated) |> MapSet.new()

    %{
      added: MapSet.difference(updated_keys, before_keys) |> MapSet.to_list() |> Enum.sort(),
      removed: MapSet.difference(before_keys, updated_keys) |> MapSet.to_list() |> Enum.sort(),
      changed:
        MapSet.intersection(before_keys, updated_keys)
        |> Enum.filter(&(Map.fetch!(before, &1) != Map.fetch!(updated, &1)))
        |> Enum.sort()
    }
  end

  defp id_list_diff(before, updated) do
    map_diff(Map.new(before, &{get(&1, :id), &1}), Map.new(updated, &{get(&1, :id), &1}))
  end

  defp revise(ir, revision), do: IR.new(ir.id, ir.objective, ir_opts(ir, revision))

  defp ir_opts(ir, revision) do
    [
      revision: revision,
      inputs: ir.inputs,
      nodes: ir.nodes,
      edges: ir.edges,
      acceptance: ir.acceptance,
      policies: ir.policies,
      holes: ir.holes,
      presentation: ir.presentation,
      metadata: ir.metadata
    ]
  end

  defp check_base_revision(ir, revision) when revision == ir.revision, do: :ok

  defp check_base_revision(ir, revision),
    do:
      operation_error(:stale_revision, "workflow edit batch has a stale base revision", %{
        expected: ir.revision,
        actual: revision
      })

  defp check_base_hash(_ir, nil), do: :ok

  defp check_base_hash(ir, hash) do
    expected = IR.semantic_hash(ir)

    if hash == expected do
      :ok
    else
      operation_error(:stale_semantic_hash, "workflow edit batch has a stale semantic hash", %{
        expected: expected,
        actual: hash
      })
    end
  end

  defp accept_report(%{status: :accepted}), do: :ok

  defp accept_report(report),
    do:
      operation_error(:operation_batch_rejected, "workflow edit batch failed draft validation", %{
        report: report
      })

  defp operation_list(operations) when is_list(operations), do: {:ok, operations}

  defp operation_list(operations),
    do:
      operation_error(:invalid_operations, "workflow edit operations must be a list", %{
        operations: operations
      })

  defp fetch_node(ir, node_id) do
    case Map.fetch(ir.nodes, node_id) do
      {:ok, node} ->
        {:ok, node}

      :error ->
        operation_error(:unknown_node, "workflow node does not exist", %{node_id: node_id})
    end
  end

  defp incident_edges(ir, node_id),
    do: Enum.filter(Map.values(ir.edges), &(&1.from.node == node_id or &1.to.node == node_id))

  defp require_cascade([], _cascade?, _node_id), do: :ok
  defp require_cascade(_edges, true, _node_id), do: :ok

  defp require_cascade(edges, false, node_id),
    do:
      operation_error(:cascade_required, "removing a connected node requires cascade: true", %{
        node_id: node_id,
        edge_ids: Enum.map(edges, & &1.id)
      })

  defp require_key(key) when is_binary(key) and key != "", do: :ok
  defp require_key(key) when is_atom(key), do: :ok

  defp require_key(key),
    do: operation_error(:invalid_key, "operation key is required", %{key: key})

  defp ensure_absent(map, key, code, message, details) do
    if Map.has_key?(map, key), do: operation_error(code, message, details), else: :ok
  end

  defp fetch_map_value(map, key, field) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        operation_error(:unknown_value, "workflow value does not exist", %{field: field, key: key})
    end
  end

  defp equivalent_key(map, key) do
    Enum.find(Map.keys(map), key, &(canonical_key(&1) == canonical_key(key)))
  end

  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(key), do: key

  defp operation_name(operation) do
    case get(operation, :op) do
      name when name in [:add_node, :replace_node, :remove_node, :connect, :disconnect] -> name
      name when name in [:set_argument, :remove_argument, :set_policy, :remove_policy] -> name
      name when name in [:set_acceptance, :remove_acceptance, :resolve_hole, :add_hole] -> name
      name when name in [:annotate, :remove_annotation] -> name
      "add_node" -> :add_node
      "replace_node" -> :replace_node
      "remove_node" -> :remove_node
      "connect" -> :connect
      "disconnect" -> :disconnect
      "set_argument" -> :set_argument
      "remove_argument" -> :remove_argument
      "set_policy" -> :set_policy
      "remove_policy" -> :remove_policy
      "set_acceptance" -> :set_acceptance
      "remove_acceptance" -> :remove_acceptance
      "resolve_hole" -> :resolve_hole
      "add_hole" -> :add_hole
      "annotate" -> :annotate
      "remove_annotation" -> :remove_annotation
      other -> other
    end
  end

  defp put_field(map, key, value) do
    if Map.has_key?(map, Atom.to_string(key)),
      do: Map.put(map, Atom.to_string(key), value),
      else: Map.put(map, key, value)
  end

  defp operation_error(code, message, details) do
    {:error,
     Error.validation(message,
       source: __MODULE__,
       details: Map.put(details, :code, code)
     )}
  end

  defp get(input, key, default \\ nil)
  defp get(input, key, default) when is_list(input), do: Keyword.get(input, key, default)

  defp get(input, key, default) when is_map(input),
    do: Map.get(input, key, Map.get(input, Atom.to_string(key), default))

  defp get(_input, _key, default), do: default
end
