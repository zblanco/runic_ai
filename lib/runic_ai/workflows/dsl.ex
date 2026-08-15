defmodule RunicAI.Workflows.DSL do
  @moduledoc """
  Strict, compact, line-oriented authoring projection for workflow IR V1.

  The DSL is parsed into canonical IR and never executed directly. Catalog
  contracts are referenced by immutable ref/hash and re-resolved while parsing.
  """

  alias RunicAI.Error
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node

  @header "runic-workflow\t1"

  @spec render(IR.t() | map()) :: {:ok, String.t()} | {:error, Error.t()}
  def render(input) do
    with {:ok, ir} <- IR.from_input(input) do
      lines =
        [
          @header,
          line("id", ir.id),
          line("objective", ir.objective),
          line("revision", ir.revision),
          line("inputs", ir.inputs),
          line("policies", ir.policies)
        ] ++
          node_lines(ir) ++
          edge_lines(ir) ++
          repeated_lines("accept", ir.acceptance) ++
          repeated_lines("hole", ir.holes) ++
          [
            line("presentation", ir.presentation),
            line("metadata", ir.metadata),
            "end"
          ]

      {:ok, Enum.join(lines, "\n") <> "\n"}
    end
  end

  @spec parse(String.t()) :: {:ok, IR.t()} | {:error, Error.t()}
  def parse(text) when is_binary(text) do
    lines = String.split(text, ~r/\r?\n/u, trim: true)

    with [@header | body] <- lines,
         true <- List.last(body) == "end" || {:error, parse_error(:missing_end)},
         {:ok, state} <- parse_lines(Enum.drop(body, -1), initial_state()),
         :ok <- require_scalar(state, :id),
         :ok <- require_scalar(state, :objective) do
      IR.new(state.id, state.objective,
        revision: state.revision,
        inputs: state.inputs,
        nodes: state.nodes,
        edges: state.edges,
        acceptance: Enum.reverse(state.acceptance),
        policies: state.policies,
        holes: Enum.reverse(state.holes),
        presentation: state.presentation,
        metadata: state.metadata
      )
    else
      [] -> {:error, parse_error(:empty_document)}
      [_other | _rest] -> {:error, parse_error(:invalid_header)}
      false -> {:error, parse_error(:invalid_document)}
      {:error, _reason} = error -> error
    end
  end

  def parse(input),
    do: {:error, parse_error(:invalid_document, %{input: input})}

  defp node_lines(ir) do
    ir.nodes
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn node ->
      [
        "node",
        json(node.id),
        json(node.component),
        json(node.kind),
        json(node.arguments),
        json(node.policy),
        json(node.metadata),
        json(contract_value(node.contract, :ref)),
        json(contract_value(node.contract, :hash))
      ]
      |> Enum.join("\t")
    end)
  end

  defp edge_lines(ir) do
    ir.edges
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn edge ->
      [
        "edge",
        json(edge.id),
        json(edge.from),
        json(edge.to),
        json(edge.mode),
        json(edge.metadata)
      ]
      |> Enum.join("\t")
    end)
  end

  defp repeated_lines(label, values), do: Enum.map(values, &line(label, &1))
  defp line(label, value), do: label <> "\t" <> json(value)
  defp json(value), do: Jason.encode!(value)

  defp initial_state do
    %{
      id: nil,
      objective: nil,
      revision: 1,
      inputs: %{},
      nodes: %{},
      edges: %{},
      acceptance: [],
      policies: %{},
      holes: [],
      presentation: %{},
      metadata: %{}
    }
  end

  defp parse_lines(lines, state) do
    Enum.reduce_while(Enum.with_index(lines, 2), {:ok, state}, fn {line, number}, {:ok, acc} ->
      case parse_line(line, acc) do
        {:ok, next} ->
          {:cont, {:ok, next}}

        {:error, %Error{} = error} ->
          error = %{error | details: Map.put(error.details || %{}, :line, number)}
          {:halt, {:error, error}}
      end
    end)
  end

  defp parse_line(line, state) do
    case String.split(line, "\t") do
      ["id", encoded] -> put_scalar(state, :id, encoded)
      ["objective", encoded] -> put_scalar(state, :objective, encoded)
      ["revision", encoded] -> put_scalar(state, :revision, encoded)
      ["inputs", encoded] -> put_scalar(state, :inputs, encoded)
      ["policies", encoded] -> put_scalar(state, :policies, encoded)
      ["presentation", encoded] -> put_scalar(state, :presentation, encoded)
      ["metadata", encoded] -> put_scalar(state, :metadata, encoded)
      ["accept", encoded] -> prepend_decoded(state, :acceptance, encoded)
      ["hole", encoded] -> prepend_decoded(state, :holes, encoded)
      ["node" | fields] -> parse_node(fields, state)
      ["edge" | fields] -> parse_edge(fields, state)
      [kind | _fields] -> {:error, parse_error(:unknown_statement, %{statement: kind})}
    end
  end

  defp parse_node(
         [id, component, kind, arguments, policy, metadata, contract_ref, contract_hash],
         state
       ) do
    with {:ok, id} <- decode(id),
         {:ok, component} <- decode(component),
         {:ok, kind} <- decode(kind),
         {:ok, arguments} <- decode(arguments),
         {:ok, policy} <- decode(policy),
         {:ok, metadata} <- decode(metadata),
         {:ok, expected_ref} <- decode(contract_ref),
         {:ok, expected_hash} <- decode(contract_hash),
         {:ok, node} <-
           Node.new(id, component,
             kind: normalize_kind(kind),
             arguments: arguments,
             policy: policy,
             metadata: metadata
           ),
         :ok <- verify_contract_pin(node, expected_ref, expected_hash),
         false <- Map.has_key?(state.nodes, node.id) do
      {:ok, put_in(state, [:nodes, node.id], node)}
    else
      true -> {:error, parse_error(:duplicate_node)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_node(_fields, _state), do: {:error, parse_error(:invalid_node_statement)}

  defp parse_edge([id, from, to, mode, metadata], state) do
    with {:ok, id} <- decode(id),
         {:ok, from} <- decode(from),
         {:ok, to} <- decode(to),
         {:ok, mode} <- decode(mode),
         {:ok, metadata} <- decode(metadata),
         {:ok, edge} <-
           Edge.new(from, to, id: id, mode: normalize_mode(mode), metadata: metadata),
         false <- Map.has_key?(state.edges, edge.id) do
      {:ok, put_in(state, [:edges, edge.id], edge)}
    else
      true -> {:error, parse_error(:duplicate_edge)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_edge(_fields, _state), do: {:error, parse_error(:invalid_edge_statement)}

  defp put_scalar(state, key, encoded) do
    with {:ok, value} <- decode(encoded) do
      {:ok, Map.put(state, key, value)}
    end
  end

  defp prepend_decoded(state, key, encoded) do
    with {:ok, value} <- decode(encoded) do
      {:ok, Map.update!(state, key, &[value | &1])}
    end
  end

  defp decode(encoded) do
    case Jason.decode(encoded) do
      {:ok, value} ->
        {:ok, value}

      {:error, error} ->
        {:error, parse_error(:invalid_json_fragment, %{error: Exception.message(error)})}
    end
  end

  defp verify_contract_pin(node, expected_ref, expected_hash) do
    actual_ref = contract_value(node.contract, :ref)
    actual_hash = contract_value(node.contract, :hash)

    if actual_ref == expected_ref and actual_hash == expected_hash do
      :ok
    else
      {:error,
       parse_error(:stale_component_contract, %{
         node_id: node.id,
         expected_ref: expected_ref,
         actual_ref: actual_ref,
         expected_hash: expected_hash,
         actual_hash: actual_hash
       })}
    end
  end

  defp require_scalar(state, key) do
    if is_binary(Map.get(state, key)) and Map.get(state, key) != "" do
      :ok
    else
      {:error, parse_error(:missing_required_statement, %{statement: key})}
    end
  end

  defp normalize_kind("component"), do: :component
  defp normalize_kind("coding"), do: :coding
  defp normalize_kind(kind), do: kind
  defp normalize_mode("data"), do: :data
  defp normalize_mode("pipeline"), do: :pipeline
  defp normalize_mode(mode), do: mode

  defp contract_value(contract, key),
    do: Map.get(contract, key, Map.get(contract, to_string(key)))

  defp parse_error(code, details \\ %{}) do
    Error.validation("workflow DSL could not be parsed",
      source: __MODULE__,
      details: Map.put(details, :code, code)
    )
  end
end
