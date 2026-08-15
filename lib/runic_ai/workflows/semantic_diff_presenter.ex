defmodule RunicAI.Workflows.SemanticDiffPresenter do
  @moduledoc """
  Builds a human review projection from typed workflow operations and diffs.

  The canonical operation batch and IR diff remain executable/auditable truth.
  This module is deliberately a projection: it never parses its own prose back
  into workflow semantics.
  """

  @type change :: %{
          required(:kind) => String.t(),
          required(:title) => String.t(),
          required(:detail) => String.t()
        }

  @spec present(map() | keyword()) :: %{summary: String.t(), changes: [change()]}
  def present(input) when is_map(input) or is_list(input) do
    operations = input |> value(:operations, []) |> List.wrap()
    diff = value(input, :diff, %{}) || %{}

    changes =
      case Enum.filter(operations, &is_map/1) do
        [] -> diff_changes(diff)
        operations -> Enum.map(operations, &operation_change/1)
      end

    count = length(changes)

    %{
      summary:
        case count do
          0 -> "No semantic changes detected"
          1 -> "1 semantic change"
          count -> "#{count} semantic changes"
        end,
      changes: changes
    }
  end

  def present(_input), do: %{summary: "No semantic changes detected", changes: []}

  defp operation_change(operation) do
    case value(operation, :op) |> to_string() do
      "add_node" ->
        node = value(operation, :node, %{})
        node_id = value(node, :id, "unnamed node")
        component = value(node, :component, "unspecified component")
        change("Flow", "Add node #{node_id}", "Uses #{component}.")

      "replace_node" ->
        node_id = value(operation, :node_id, "unknown node")
        component = operation |> value(:node, %{}) |> value(:component, "unspecified component")
        change("Flow", "Replace node #{node_id}", "New component: #{component}.")

      "remove_node" ->
        node_id = value(operation, :node_id, "unknown node")

        cascade =
          if value(operation, :cascade, false), do: " Connected edges are also removed.", else: ""

        change("Flow", "Remove node #{node_id}", "The node is removed.#{cascade}")

      "connect" ->
        edge = value(operation, :edge, operation)
        from = endpoint(value(edge, :from))
        to = endpoint(value(edge, :to))
        change("Flow", "Connect #{from} to #{to}", "Data will flow through this connection.")

      "disconnect" ->
        edge_id = value(operation, :edge_id, "unknown edge")

        change(
          "Flow",
          "Disconnect edge #{edge_id}",
          "Data will no longer flow through this connection."
        )

      "set_argument" ->
        node_id = value(operation, :node_id, "unknown node")
        key = human_key(value(operation, :key, "argument"))

        change(
          "Node",
          "Change #{node_id} #{key}",
          "New value: #{render(value(operation, :value))}."
        )

      "remove_argument" ->
        node_id = value(operation, :node_id, "unknown node")
        key = human_key(value(operation, :key, "argument"))
        change("Node", "Remove #{node_id} #{key}", "The component default will apply.")

      "set_policy" ->
        scope = policy_scope(operation)
        key = human_key(value(operation, :key, "policy"))
        change("Policy", "Set #{scope} #{key}", "New value: #{render(value(operation, :value))}.")

      "remove_policy" ->
        scope = policy_scope(operation)
        key = human_key(value(operation, :key, "policy"))
        change("Policy", "Remove #{scope} #{key}", "The inherited or default policy will apply.")

      "set_acceptance" ->
        check = value(operation, :check, %{})
        check_id = value(operation, :acceptance_id, value(check, :id, "acceptance check"))

        description =
          value(check, :description, value(check, :condition, "Completion proof changed."))

        change("Proof", "Set acceptance #{check_id}", sentence(description))

      "remove_acceptance" ->
        check_id = value(operation, :acceptance_id, "acceptance check")

        change(
          "Proof",
          "Remove acceptance #{check_id}",
          "This completion requirement will no longer be checked."
        )

      "resolve_hole" ->
        hole_id = value(operation, :hole_id, "unresolved question")

        change(
          "Decision",
          "Resolve #{hole_id}",
          "This item will no longer block runnable validation."
        )

      "add_hole" ->
        hole = value(operation, :hole, %{})
        hole_id = value(hole, :id, "unresolved question")
        need = value(hole, :need, "Operator input is required.")
        change("Decision", "Add unresolved item #{hole_id}", sentence(need))

      "annotate" ->
        target = value(operation, :node_id, "workflow")
        key = human_key(value(operation, :key, "annotation"))
        change("Note", "Annotate #{target} #{key}", "Value: #{render(value(operation, :value))}.")

      "remove_annotation" ->
        target = value(operation, :node_id, "workflow")
        key = human_key(value(operation, :key, "annotation"))

        change(
          "Note",
          "Remove #{target} #{key}",
          "The annotation is removed; execution semantics are unchanged."
        )

      unknown ->
        change(
          "Change",
          "Apply #{human_key(unknown)}",
          "Inspect the raw transaction for full details."
        )
    end
  end

  defp diff_changes(diff) when is_map(diff) do
    []
    |> add_collection_changes("Node", value(diff, :nodes, %{}))
    |> add_collection_changes("Connection", value(diff, :edges, %{}))
    |> add_collection_changes("Acceptance", value(diff, :acceptance, %{}))
    |> add_collection_changes("Unresolved item", value(diff, :holes, %{}))
    |> add_value_change("Workflow policy", value(diff, :workflow_policy, %{}))
    |> add_value_change("Workflow metadata", value(diff, :workflow_metadata, %{}))
    |> Enum.reverse()
  end

  defp diff_changes(_diff), do: []

  defp add_collection_changes(changes, label, collection) when is_map(collection) do
    changes
    |> add_ids(label, "added", value(collection, :added, []))
    |> add_ids(label, "removed", value(collection, :removed, []))
    |> add_ids(label, "changed", value(collection, :changed, []))
  end

  defp add_collection_changes(changes, _label, _collection), do: changes

  defp add_ids(changes, _label, _verb, []), do: changes

  defp add_ids(changes, label, verb, ids) do
    [
      change(label, "#{label} #{verb}", Enum.map_join(List.wrap(ids), ", ", &to_string/1))
      | changes
    ]
  end

  defp add_value_change(changes, label, value_change) when is_map(value_change) do
    if value(value_change, :changed?, false) do
      before = render(value(value_change, :before))
      after_value = render(value(value_change, :after))
      [change(label, "#{label} changed", "Before: #{before}. After: #{after_value}.") | changes]
    else
      changes
    end
  end

  defp add_value_change(changes, _label, _value_change), do: changes

  defp change(kind, title, detail), do: %{kind: kind, title: title, detail: detail}

  defp policy_scope(operation) do
    case value(operation, :node_id) do
      node_id when is_binary(node_id) and node_id != "" -> "#{node_id} policy"
      _other -> "workflow policy"
    end
  end

  defp endpoint(endpoint) when is_map(endpoint) do
    node = value(endpoint, :node, "unknown")
    port = value(endpoint, :port)
    if is_nil(port), do: to_string(node), else: "#{node}.#{port}"
  end

  defp endpoint(endpoint) when is_binary(endpoint), do: endpoint
  defp endpoint(_endpoint), do: "unknown endpoint"

  defp human_key(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
  end

  defp sentence(value) when is_binary(value) do
    value = String.trim(value)
    if String.ends_with?(value, [".", "!", "?"]), do: value, else: value <> "."
  end

  defp sentence(value), do: sentence(render(value))

  defp render(nil), do: "none"
  defp render(value) when is_binary(value), do: value

  defp render(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp render(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value, limit: 20, printable_limit: 500)
    end
  end

  defp value(input, key, default \\ nil)
  defp value(input, key, default) when is_list(input), do: Keyword.get(input, key, default)

  defp value(input, key, default) when is_map(input),
    do: Map.get(input, key, Map.get(input, Atom.to_string(key), default))

  defp value(_input, _key, default), do: default
end
