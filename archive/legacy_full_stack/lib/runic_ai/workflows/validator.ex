defmodule RunicAI.Workflows.Validator do
  @moduledoc """
  Progressive semantic validator for workflow IR V1.

  Draft validation preserves explicit holes and incomplete acceptance as
  actionable warnings. Runnable validation closes those gaps and requires the
  pinned catalog contracts, exact ports, topology, and policies to be sound.
  """

  alias RunicAI.Error
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node

  @type mode :: :draft | :runnable
  @type diagnostic :: %{
          required(:severity) => :info | :warning | :error,
          required(:code) => atom(),
          required(:message) => String.t(),
          required(:details) => map()
        }
  @type report :: %{
          required(:status) => :accepted | :rejected,
          required(:mode) => mode(),
          required(:workflow_id) => String.t() | nil,
          required(:semantic_hash) => String.t() | nil,
          required(:diagnostics) => [diagnostic()]
        }

  @spec report(IR.t() | map(), keyword()) :: report()
  def report(input, opts \\ []) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :draft)

    case IR.from_input(input) do
      {:ok, ir} ->
        diagnostics =
          []
          |> check_mode(mode)
          |> check_nodes(ir, mode)
          |> check_edges(ir, mode)
          |> check_input_occupancy(ir)
          |> check_required_inputs(ir, mode)
          |> check_cycles(ir)
          |> check_holes(ir, mode)
          |> check_acceptance(ir, mode)
          |> Enum.reverse()

        %{
          status:
            if(Enum.any?(diagnostics, &(&1.severity == :error)),
              do: :rejected,
              else: :accepted
            ),
          mode: mode,
          workflow_id: ir.id,
          semantic_hash: IR.semantic_hash(ir),
          diagnostics: diagnostics
        }

      {:error, %Error{} = error} ->
        %{
          status: :rejected,
          mode: mode,
          workflow_id: nil,
          semantic_hash: nil,
          diagnostics: [
            diagnostic(:error, :invalid_workflow_ir, error.message, %{error: error})
          ]
        }
    end
  end

  @spec validate(IR.t() | map(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def validate(input, opts \\ []) do
    report = report(input, opts)

    if report.status == :accepted do
      {:ok, report}
    else
      {:error,
       Error.validation("workflow IR rejected",
         source: __MODULE__,
         details: %{code: :workflow_ir_rejected, report: report}
       )}
    end
  end

  defp check_mode(diagnostics, mode) when mode in [:draft, :runnable], do: diagnostics

  defp check_mode(diagnostics, mode) do
    [
      diagnostic(:error, :invalid_validation_mode, "invalid workflow validation mode", %{
        mode: mode
      })
      | diagnostics
    ]
  end

  defp check_nodes(diagnostics, %IR{nodes: nodes}, mode) do
    Enum.reduce(nodes, diagnostics, fn {id, %Node{} = node}, acc ->
      acc
      |> check_node_identity(id, node)
      |> check_contract_pin(node, mode)
      |> check_replay_policy(node, mode)
    end)
  end

  defp check_replay_policy(diagnostics, %Node{} = node, mode) do
    replay = value(node.contract, :replay, %{})
    automatic_retry? = value(replay, :automatic_retry?, false)
    max_retries = requested_max_retries(node.policy)

    if node.effects != [] and max_retries > 0 and not automatic_retry? do
      [
        diagnostic(
          severity(mode),
          :unsafe_effect_retry,
          "effectful component does not declare an automatic retry reconciliation contract",
          %{
            node_id: node.id,
            component: node.component,
            effects: node.effects,
            max_retries: max_retries,
            replay: replay
          }
        )
        | diagnostics
      ]
    else
      diagnostics
    end
  end

  defp requested_max_retries(policy) when is_map(policy) do
    case value(policy, :max_retries) || value(policy, :retries) do
      retries when is_integer(retries) and retries > 0 -> retries
      _other -> scheduler_max_retries(value(policy, :scheduler))
    end
  end

  defp requested_max_retries(_policy), do: 0

  defp scheduler_max_retries(value) when value in [:io, "io"], do: 2
  defp scheduler_max_retries(value) when value in [:llm, "llm"], do: 3
  defp scheduler_max_retries(_value), do: 0

  defp check_node_identity(diagnostics, id, %Node{id: id}), do: diagnostics

  defp check_node_identity(diagnostics, id, %Node{id: node_id}) do
    [
      diagnostic(:error, :node_key_mismatch, "workflow node key does not match its id", %{
        key: id,
        node_id: node_id
      })
      | diagnostics
    ]
  end

  defp check_contract_pin(diagnostics, %Node{} = node, mode) do
    case Catalog.resolve(node.component) do
      {:ok, current} ->
        pinned_ref = value(node.contract, :ref)
        pinned_hash = value(node.contract, :hash)

        cond do
          value(node.contract, :key) != node.component ->
            [
              diagnostic(
                :error,
                :component_contract_key_mismatch,
                "node component does not match its pinned contract key",
                %{
                  node_id: node.id,
                  component: node.component,
                  contract_key: value(node.contract, :key)
                }
              )
              | diagnostics
            ]

          pinned_ref != current.ref or pinned_hash != current.hash ->
            [
              diagnostic(
                severity(mode),
                :stale_component_contract,
                "pinned component contract differs from the current catalog",
                %{
                  node_id: node.id,
                  pinned_ref: pinned_ref,
                  current_ref: current.ref,
                  pinned_hash: pinned_hash,
                  current_hash: current.hash
                }
              )
              | diagnostics
            ]

          true ->
            diagnostics
        end

      {:error, %Error{} = error} ->
        [
          diagnostic(:error, :unknown_component_contract, error.message, %{
            node_id: node.id,
            component: node.component
          })
          | diagnostics
        ]
    end
  end

  defp check_edges(diagnostics, %IR{} = ir, mode) do
    Enum.reduce(ir.edges, diagnostics, fn {id, %Edge{} = edge}, acc ->
      acc
      |> check_edge_identity(id, edge)
      |> check_edge_nodes(ir, edge)
      |> check_edge_ports(ir, edge, mode)
    end)
  end

  defp check_edge_identity(diagnostics, id, %Edge{id: id}), do: diagnostics

  defp check_edge_identity(diagnostics, id, %Edge{id: edge_id}) do
    [
      diagnostic(:error, :edge_key_mismatch, "workflow edge key does not match its id", %{
        key: id,
        edge_id: edge_id
      })
      | diagnostics
    ]
  end

  defp check_edge_nodes(diagnostics, %IR{nodes: nodes}, %Edge{} = edge) do
    diagnostics
    |> maybe_unknown_node(edge, :from, Map.has_key?(nodes, edge.from.node))
    |> maybe_unknown_node(edge, :to, Map.has_key?(nodes, edge.to.node))
  end

  defp maybe_unknown_node(diagnostics, _edge, _side, true), do: diagnostics

  defp maybe_unknown_node(diagnostics, edge, side, false) do
    endpoint = Map.fetch!(edge, side)

    [
      diagnostic(:error, :unknown_edge_node, "edge references an unknown node", %{
        edge_id: edge.id,
        side: side,
        node_id: endpoint.node
      })
      | diagnostics
    ]
  end

  defp check_edge_ports(diagnostics, %IR{nodes: nodes}, %Edge{} = edge, mode) do
    with %Node{} = producer <- Map.get(nodes, edge.from.node),
         %Node{} = consumer <- Map.get(nodes, edge.to.node),
         {:ok, output} <- fetch_port(producer.contract, :outputs, edge.from.port),
         {:ok, input} <- fetch_port(consumer.contract, :inputs, edge.to.port) do
      output_contract = value(output, :contract)
      input_contract = value(input, :contract)

      diagnostics =
        if assignable?(output_contract, input_contract) do
          diagnostics
        else
          [
            diagnostic(
              :error,
              :incompatible_port_contract,
              "producer output is not safely assignable to consumer input",
              %{
                edge_id: edge.id,
                from: edge.from,
                to: edge.to,
                output_contract: output_contract,
                input_contract: input_contract
              }
            )
            | diagnostics
          ]
        end

      if any_contract?(output_contract) or any_contract?(input_contract) do
        [
          diagnostic(
            any_severity(mode, producer, consumer),
            :untyped_port_boundary,
            "edge crosses an untyped contract boundary",
            %{
              edge_id: edge.id,
              from: edge.from,
              to: edge.to,
              effects: Enum.uniq(producer.effects ++ consumer.effects)
            }
          )
          | diagnostics
        ]
      else
        diagnostics
      end
    else
      {:error, {side, port, available}} ->
        [
          diagnostic(:error, :unknown_edge_port, "edge references an unknown component port", %{
            edge_id: edge.id,
            side: side,
            port: port,
            available: available
          })
          | diagnostics
        ]

      nil ->
        diagnostics
    end
  end

  defp fetch_port(contract, side, port) do
    ports = value(contract, side, %{})

    case Map.get(ports, port, Map.get(ports, maybe_existing_atom(port))) do
      nil -> {:error, {side, port, Enum.map(Map.keys(ports), &to_string/1)}}
      schema -> {:ok, schema}
    end
  end

  defp check_input_occupancy(diagnostics, %IR{edges: edges}) do
    conflicts =
      edges
      |> Map.values()
      |> Enum.group_by(&{&1.to.node, &1.to.port})
      |> Enum.filter(fn {_endpoint, grouped} -> length(grouped) > 1 end)

    Enum.reduce(conflicts, diagnostics, fn {{node, port}, grouped}, acc ->
      [
        diagnostic(:error, :input_port_already_connected, "input port has multiple producers", %{
          node_id: node,
          port: port,
          edge_ids: Enum.map(grouped, & &1.id)
        })
        | acc
      ]
    end)
  end

  defp check_required_inputs(diagnostics, %IR{} = ir, mode) do
    roots = root_node_ids(ir)

    Enum.reduce(ir.nodes, diagnostics, fn {id, node}, acc ->
      if MapSet.member?(roots, id) do
        acc
      else
        required_ports =
          node.contract
          |> value(:inputs, %{})
          |> Enum.filter(fn {_name, schema} -> value(schema, :required, true) end)
          |> Enum.map(fn {name, _schema} -> to_string(name) end)

        connected =
          ir.edges
          |> Map.values()
          |> Enum.filter(&(&1.to.node == id))
          |> Enum.map(& &1.to.port)

        Enum.reduce(required_ports -- connected, acc, fn port, inner_acc ->
          [
            diagnostic(
              severity(mode),
              :required_input_unbound,
              "required component input is not connected",
              %{node_id: id, port: port}
            )
            | inner_acc
          ]
        end)
      end
    end)
  end

  defp check_cycles(diagnostics, %IR{} = ir) do
    if acyclic?(ir) do
      diagnostics
    else
      [diagnostic(:error, :cycle, "workflow IR V1 graph must be acyclic", %{}) | diagnostics]
    end
  end

  defp check_holes(diagnostics, %IR{holes: []}, _mode), do: diagnostics

  defp check_holes(diagnostics, %IR{holes: holes}, mode) do
    [
      diagnostic(
        severity(mode),
        :unresolved_holes,
        "workflow contains unresolved design holes",
        %{
          holes: holes
        }
      )
      | diagnostics
    ]
  end

  defp check_acceptance(diagnostics, %IR{acceptance: []}, mode) do
    [
      diagnostic(
        severity(mode),
        :missing_acceptance,
        "workflow does not declare required acceptance evidence",
        %{}
      )
      | diagnostics
    ]
  end

  defp check_acceptance(diagnostics, %IR{}, _mode), do: diagnostics

  defp acyclic?(%IR{} = ir) do
    indegree = Map.new(ir.nodes, fn {id, _node} -> {id, 0} end)

    indegree =
      Enum.reduce(ir.edges, indegree, fn {_id, edge}, acc ->
        if Map.has_key?(acc, edge.to.node),
          do: Map.update!(acc, edge.to.node, &(&1 + 1)),
          else: acc
      end)

    queue = for {id, 0} <- indegree, do: id
    visited = visit(queue, indegree, outgoing(ir), 0)
    visited == map_size(ir.nodes)
  end

  defp visit([], _indegree, _outgoing, visited), do: visited

  defp visit([id | rest], indegree, outgoing, visited) do
    {indegree, newly_ready} =
      outgoing
      |> Map.get(id, [])
      |> Enum.reduce({indegree, []}, fn child, {degrees, ready} ->
        degrees = Map.update!(degrees, child, &(&1 - 1))
        ready = if Map.fetch!(degrees, child) == 0, do: [child | ready], else: ready
        {degrees, ready}
      end)

    visit(rest ++ Enum.reverse(newly_ready), indegree, outgoing, visited + 1)
  end

  defp outgoing(%IR{} = ir) do
    Enum.reduce(ir.edges, %{}, fn {_id, edge}, acc ->
      if Map.has_key?(ir.nodes, edge.from.node) and Map.has_key?(ir.nodes, edge.to.node) do
        Map.update(acc, edge.from.node, [edge.to.node], &[edge.to.node | &1])
      else
        acc
      end
    end)
  end

  defp root_node_ids(%IR{} = ir) do
    children = ir.edges |> Map.values() |> Enum.map(& &1.to.node) |> MapSet.new()

    ir.nodes
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(children, &1))
    |> MapSet.new()
  end

  defp assignable?("any", _target), do: true
  defp assignable?(_source, "any"), do: true

  defp assignable?(source, target) when is_binary(source) and is_binary(target),
    do: source == target

  defp assignable?(source, target) do
    source_options = one_of(source)
    target_options = one_of(target)

    cond do
      not is_nil(source_options) ->
        Enum.all?(source_options, &assignable?(&1, target))

      not is_nil(target_options) ->
        Enum.any?(target_options, &assignable?(source, &1))

      list_type?(source) and list_type?(target) ->
        assignable?(value(source, :list), value(target, :list))

      true ->
        source == target
    end
  end

  defp one_of(contract) when is_map(contract), do: value(contract, :one_of)
  defp one_of(_contract), do: nil

  defp list_type?(contract) when is_map(contract), do: not is_nil(value(contract, :list))
  defp list_type?(_contract), do: false

  defp any_contract?("any"), do: true

  defp any_contract?(contract) do
    case one_of(contract) do
      nil -> false
      options -> Enum.any?(options, &any_contract?/1)
    end
  end

  defp any_severity(:runnable, producer, consumer) do
    if producer.effects != [] or consumer.effects != [], do: :error, else: :warning
  end

  defp any_severity(_mode, _producer, _consumer), do: :warning
  defp severity(:runnable), do: :error
  defp severity(_mode), do: :warning

  defp diagnostic(severity, code, message, details) do
    %{severity: severity, code: code, message: message, details: details}
  end

  defp maybe_existing_atom(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> nil
    end
  end

  defp maybe_existing_atom(value) when is_atom(value), do: value
  defp maybe_existing_atom(_value), do: nil

  defp value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
