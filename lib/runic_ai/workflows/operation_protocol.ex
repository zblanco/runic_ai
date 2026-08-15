defmodule RunicAI.Workflows.OperationProtocol do
  @moduledoc """
  Shared agent-facing protocol for targeted workflow IR edits.

  The protocol keeps revision and semantic-hash preconditions server-owned and
  exposes a compact editable manifest instead of asking an agent to regenerate
  the full canonical IR or repeat component contract bodies.
  """

  alias RunicAI.Workflows.IR

  @spec grammar() :: String.t()
  def grammar do
    """
    Return only JSON in the shape {"operations": [...]} using these operations:
    set_policy, remove_policy, set_argument, remove_argument, set_acceptance,
    remove_acceptance, add_node, replace_node, remove_node, connect, disconnect,
    resolve_hole, add_hole, annotate, remove_annotation.
    Field grammar:
    - set_argument: op,node_id,key,value; remove_argument: op,node_id,key
    - set_policy: op,key,value and optional node_id; remove_policy: op,key and optional node_id
    - annotate: op,key,value and optional node_id; remove_annotation: op,key and optional node_id
    - set_acceptance: op,acceptance_id,check where check is a complete JSON object,
      for example {"op":"set_acceptance","acceptance_id":"artifact_ready",
      "check":{"id":"artifact_ready","kind":"declared_stop_condition",
      "condition":"artifact verified","required":true}}
      When replacing an existing check, preserve its kind-specific fields and
      update their values for the new objective; do not replace condition with
      description or omit kind.
      Never use a string for check. remove_acceptance: op,acceptance_id
    - add_node: op,node; replace_node: op,node_id,node; remove_node: op,node_id,cascade
    - connect: op,from,to and optional edge_id/mode; from and to are objects
      shaped {"node":"stable_node_id","port":"exact_port_name"}, never "node.port" strings
    - disconnect: op,edge_id
    - resolve_hole: op,hole_id; add_hole: op,hole
    Node targeting always uses node_id, never node.
    Make the smallest exact change. Do not regenerate the workflow.
    """
  end

  @spec editable_manifest(IR.t()) :: map()
  def editable_manifest(%IR{} = ir) do
    %{
      workflow: %{
        id: ir.id,
        policies: ir.policies,
        acceptance: ir.acceptance,
        holes: ir.holes,
        metadata: ir.metadata
      },
      nodes:
        ir.nodes
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn node ->
          %{
            id: node.id,
            component: node.component,
            contract_ref: contract_value(node.contract, :ref),
            arguments: node.arguments,
            policy: node.policy,
            metadata: node.metadata
          }
        end),
      edges:
        ir.edges
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn edge ->
          %{id: edge.id, from: edge.from, to: edge.to, mode: edge.mode}
        end)
    }
  end

  @spec batch(IR.t(), [map()]) :: map()
  def batch(%IR{} = ir, operations) when is_list(operations) do
    %{
      base_revision: ir.revision,
      base_hash: IR.semantic_hash(ir),
      operations: operations
    }
  end

  defp contract_value(contract, key) when is_map(contract) do
    Map.get(contract, key, Map.get(contract, Atom.to_string(key)))
  end
end
