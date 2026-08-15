defmodule RunicAI.Workflows.Adapters.CodingProposal do
  @moduledoc """
  Loss-reporting adapter from the current coding RLM proposal into workflow IR
  V1.

  Coding node behavior remains an explicit domain dialect and lowers through a
  typed adapter into the existing coding compiler. This preserves its stronger
  workspace and verification semantics without claiming it is equivalent to a
  general component node.
  """

  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Error
  alias RunicAI.Workflows.AdapterResult
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node

  @spec adapt(WorkflowProposal.t() | map()) :: {:ok, AdapterResult.t()} | {:error, Error.t()}
  def adapt(input) do
    with {:ok, proposal} <- WorkflowProposal.from_input(input),
         {:ok, nodes} <- nodes(proposal),
         {:ok, edges} <- edges(proposal.edges),
         {:ok, ir} <-
           IR.new(proposal.id, proposal.objective,
             nodes: nodes,
             edges: edges,
             acceptance: acceptance(proposal),
             policies: proposal.policies,
             metadata: %{
               source_representation: :coding_workflow_proposal,
               source_metadata: proposal.metadata,
               assumptions: proposal.assumptions,
               sources: proposal.sources
             }
           ) do
      diagnostics = [
        %{
          severity: :warning,
          code: :domain_lowering_required,
          message:
            "coding proposal semantics are preserved as a versioned domain dialect and require the coding lowering adapter",
          details: %{dialect: :coding, node_count: map_size(nodes)}
        }
      ]

      {:ok, %AdapterResult{ir: ir, diagnostics: diagnostics, lossless?: false}}
    end
  end

  defp nodes(proposal) do
    Enum.reduce_while(proposal.nodes, {:ok, %{}}, fn proposal_node, {:ok, acc} ->
      case Node.new(proposal_node.id, Catalog.coding_key(proposal_node.kind),
             kind: :coding,
             arguments: proposal_node.params,
             policy: proposal_node.policy,
             metadata: %{
               source_kind: proposal_node.kind,
               legacy_inputs: proposal_node.inputs,
               legacy_outputs: proposal_node.outputs,
               provenance: proposal_node.provenance,
               source_metadata: proposal_node.metadata
             }
           ) do
        {:ok, node} -> {:cont, {:ok, Map.put(acc, node.id, node)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp edges(edges) do
    Enum.reduce_while(edges, {:ok, %{}}, fn edge, {:ok, acc} ->
      case Edge.new(
             %{node: edge.from, port: "context"},
             %{node: edge.to, port: "context"},
             metadata: %{source_representation: :implicit_context_edge}
           ) do
        {:ok, ir_edge} -> {:cont, {:ok, Map.put(acc, ir_edge.id, ir_edge)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp acceptance(proposal) do
    stop_conditions =
      proposal.stop_conditions
      |> Enum.with_index(1)
      |> Enum.map(fn {condition, index} ->
        %{
          id: "stop_#{index}",
          kind: :declared_stop_condition,
          condition: condition,
          required: true
        }
      end)

    artifacts =
      proposal.expected_artifacts
      |> Enum.with_index(1)
      |> Enum.map(fn {artifact, index} ->
        %{id: "artifact_#{index}", kind: :expected_artifact, artifact: artifact, required: true}
      end)

    stop_conditions ++ artifacts
  end
end
