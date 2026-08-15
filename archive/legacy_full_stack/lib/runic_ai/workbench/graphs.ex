defmodule RunicAI.Workbench.Graphs do
  @moduledoc """
  Read-model graph projections for the local web workbench.

  The browser owns presentation. This module keeps graph source selection,
  built-in agent shapes, and persisted run overlays behind a small data API.
  """

  alias RunicAI.Persistence.Inspection
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.Schemas.RunArtifact
  alias RunicAI.Terminal.GraphPresenter

  @agent_order ["assistant", "standard", "rlm"]

  @agents %{
    "assistant" => %{
      id: "assistant",
      name: "Assistant",
      agent: "assistant",
      purpose: "General-purpose local assistant backed by dynamic RLM workflow generation.",
      default_approval: "safe",
      default_concurrency: "bounded async: 4 / 4 / 80",
      tools: ["LLM leaves", "workflow repair", "artifact writer", "scorecard"],
      graph: %{
        objective: "Assistant dynamic workflow",
        nodes: [
          %{id: "objective", kind: "input", label: "Objective"},
          %{id: "context", kind: "retrieval", label: "Context and source cues"},
          %{id: "blueprint", kind: "rlm", label: "Generate workflow blueprint"},
          %{id: "validate", kind: "guard", label: "Validate and repair"},
          %{id: "runic", kind: "workflow", label: "Materialize Runic graph"},
          %{id: "execute", kind: "runtime", label: "Execute graph"},
          %{id: "scorecard", kind: "verification", label: "Objective scorecard"},
          %{id: "answer", kind: "output", label: "Final answer"}
        ],
        edges: [
          %{from: "objective", to: "context"},
          %{from: "context", to: "blueprint"},
          %{from: "blueprint", to: "validate"},
          %{from: "validate", to: "runic"},
          %{from: "runic", to: "execute"},
          %{from: "execute", to: "scorecard"},
          %{from: "scorecard", to: "answer"}
        ]
      }
    },
    "standard" => %{
      id: "standard",
      name: "Standard/ReAct",
      agent: "standard",
      purpose: "Coding-agent loop for repo inspection, tool use, review gates, and verification.",
      default_approval: "safe",
      default_concurrency: "sequential unless explicitly overridden",
      tools: ["workspace tools", "command runner", "review gate", "verification"],
      graph: %{
        objective: "Standard/ReAct coding loop",
        nodes: [
          %{id: "objective", kind: "input", label: "Objective"},
          %{id: "plan", kind: "reasoning", label: "Plan next action"},
          %{id: "tool_policy", kind: "guard", label: "Authorize tool"},
          %{id: "tool_call", kind: "tool", label: "Execute tool"},
          %{id: "review", kind: "hitl", label: "Review risky action"},
          %{id: "verification", kind: "verification", label: "Run checks"},
          %{id: "report", kind: "output", label: "Report result"}
        ],
        edges: [
          %{from: "objective", to: "plan"},
          %{from: "plan", to: "tool_policy"},
          %{from: "tool_policy", to: "tool_call", label: "safe"},
          %{from: "tool_policy", to: "review", label: "risky"},
          %{from: "review", to: "tool_call", label: "approved"},
          %{from: "tool_call", to: "verification"},
          %{from: "verification", to: "plan", label: "repair"},
          %{from: "verification", to: "report", label: "satisfied"}
        ]
      }
    },
    "rlm" => %{
      id: "rlm",
      name: "RLM",
      agent: "rlm",
      purpose: "Recursive language-machine workflow proposal, validation, execution, and repair.",
      default_approval: "safe",
      default_concurrency: "explicit CLI/runtime controls",
      tools: ["proposal generator", "validator", "compiler", "repair controller"],
      graph: %{
        objective: "RLM generated workflow",
        nodes: [
          %{id: "objective", kind: "input", label: "Objective"},
          %{id: "proposal", kind: "proposal", label: "Generate proposal graph"},
          %{id: "validate", kind: "validation", label: "Validate proposal"},
          %{id: "compile", kind: "compiler", label: "Compile Runic graph"},
          %{id: "execute", kind: "runtime", label: "Execute nodes"},
          %{id: "repair", kind: "repair", label: "Repair failed graph"},
          %{id: "scorecard", kind: "scorecard", label: "Score objective"},
          %{id: "output", kind: "output", label: "Answer and artifacts"}
        ],
        edges: [
          %{from: "objective", to: "proposal"},
          %{from: "proposal", to: "validate"},
          %{from: "validate", to: "compile", label: "accepted"},
          %{from: "validate", to: "repair", label: "rejected"},
          %{from: "repair", to: "validate"},
          %{from: "compile", to: "execute"},
          %{from: "execute", to: "scorecard"},
          %{from: "scorecard", to: "repair", label: "incomplete"},
          %{from: "scorecard", to: "output", label: "satisfied"}
        ]
      }
    }
  }

  @spec agent_index(Store.t(), keyword()) :: [map()]
  def agent_index(%Store{} = store, opts \\ []) do
    recent = Queries.recent_sessions(store, limit: Keyword.get(opts, :recent_limit, 80))

    Enum.map(@agent_order, fn id ->
      agent =
        @agents
        |> Map.fetch!(id)
        |> Map.put(:metrics, agent_metrics(recent, id))
        |> Map.put(:last_runs, recent_agent_runs(recent, id))

      put_graph(agent, agent.graph, "Built-in #{agent.name} graph")
    end)
  end

  @spec agent_detail(Store.t(), String.t()) :: map() | nil
  def agent_detail(%Store{} = store, agent_id) when is_binary(agent_id) do
    store
    |> agent_index()
    |> Enum.find(&(&1.id == agent_id))
  end

  @spec run_graph(Store.t(), String.t(), keyword()) :: map()
  def run_graph(%Store{} = store, run_id, opts \\ []) when is_binary(run_id) do
    requested = opts |> Keyword.get(:kind, "materialized") |> normalize_kind()
    available = available_run_sources(store, run_id)

    kind =
      if Enum.any?(available, &(&1.id == requested)), do: requested, else: first_kind(available)

    source = source_for_kind(store, run_id, kind)
    graph = graph_payload(source)
    nodes = normalize_nodes(graph)
    node_events = node_events(store, run_id)

    nodes =
      Enum.map(
        nodes,
        &Map.put(&1, :status, Map.get(node_events, &1.id, %{})[:status] || &1.status)
      )

    selected_node_id = selected_node_id(opts[:node], nodes)

    graph_with_overlay = Map.put(graph, :nodes, nodes)
    edges = normalize_edges(graph, nodes)

    %{
      run_id: run_id,
      kind: kind,
      available_sources: available,
      title: source.title,
      mermaid: source.mermaid || GraphPresenter.to_mermaid(graph_with_overlay),
      fallback: GraphPresenter.adjacency_text(graph_with_overlay),
      metadata: source.metadata,
      nodes: nodes,
      edges: edges,
      selected_node: selected_node(nodes, selected_node_id, node_events),
      source_hash: hash_source(source.mermaid || inspect(graph)),
      invalid?: source.invalid?
    }
  end

  @spec built_in_agent_ids() :: [String.t()]
  def built_in_agent_ids, do: @agent_order

  defp put_graph(agent, graph, title) do
    nodes = normalize_nodes(graph)

    agent
    |> Map.put(:graph_source, %{
      title: title,
      mermaid: GraphPresenter.to_mermaid(graph),
      fallback: GraphPresenter.adjacency_text(graph),
      metadata: %{kind: "static", nodes: length(graph.nodes), edges: length(graph.edges)},
      nodes: nodes,
      edges: normalize_edges(graph, nodes),
      source_hash: hash_source(inspect(graph))
    })
  end

  defp agent_metrics(sessions, agent_id) do
    matching = Enum.filter(sessions, &(&1.agent_kind == agent_id))

    %{
      total_recent: length(matching),
      completed: Enum.count(matching, &(&1.status == "completed")),
      failed: Enum.count(matching, &(&1.status == "failed")),
      running: Enum.count(matching, &(&1.status in ["running", "waiting", "review"]))
    }
  end

  defp recent_agent_runs(sessions, agent_id) do
    sessions
    |> Enum.filter(&(&1.agent_kind == agent_id))
    |> Enum.take(5)
    |> Enum.map(fn session ->
      %{
        id: session.id,
        title: session.objective || session.id,
        status: session.status || "unknown",
        started_at: session.started_at
      }
    end)
  end

  defp available_run_sources(store, run_id) do
    [
      source_option("proposal", "Proposal", proposal_graph(store, run_id)),
      source_option("materialized", "Materialized", materialized_graph(store, run_id)),
      source_option("execution", "Execution", execution_graph(store, run_id))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp source_option(_id, _label, nil), do: nil

  defp source_option(id, label, _source) do
    %{id: id, label: label}
  end

  defp source_for_kind(store, run_id, "proposal"), do: proposal_graph(store, run_id)
  defp source_for_kind(store, run_id, "execution"), do: execution_graph(store, run_id)

  defp source_for_kind(store, run_id, _kind),
    do: materialized_graph(store, run_id) || execution_graph(store, run_id)

  defp proposal_graph(store, run_id) do
    blueprint =
      run_metadata(store, run_id, "blueprint") ||
        artifact_payload(store, run_id, "workflow_blueprint")

    case blueprint do
      nil ->
        nil

      graph ->
        graph_source("Generated proposal graph", graph, %{kind: "proposal"})
    end
  end

  defp materialized_graph(store, run_id) do
    case Inspection.graph_summary(store, run_id) do
      nil ->
        nil

      %{} = graph ->
        mermaid =
          graph
          |> field(:runic)
          |> field(:serializers)
          |> field(:mermaid)

        graph_source("Materialized Runic workflow graph", graph, %{kind: "materialized"},
          mermaid: mermaid
        )
    end
  end

  defp execution_graph(store, run_id) do
    events = Queries.terminal_events_for_session(store, run_id)
    runnable_events = Queries.runnable_events(store, run_id)

    nodes =
      runnable_events
      |> Enum.map(fn event ->
        %{
          id:
            event.node_name || event.component_id || event.runnable_id ||
              "runnable_#{event.sequence}",
          label:
            event.node_name || event.component_id || event.runnable_id ||
              "runnable #{event.sequence}",
          kind: event.component_type || event.stage || "runnable",
          status: event.status
        }
      end)
      |> Kernel.++(
        Enum.map(events, fn event ->
          %{
            id: event.phase || event.kind || "event_#{event.sequence}",
            label: event.title || event.phase || event.kind,
            kind: event.kind || "event",
            status: event.status,
            sequence: event.sequence
          }
        end)
      )
      |> Enum.reject(&is_nil(&1.id))
      |> Enum.uniq_by(& &1.id)

    edges =
      nodes
      |> Enum.map(& &1.id)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> %{from: from, to: to, label: "then"} end)

    if nodes == [] do
      nil
    else
      graph_source("Observed execution path", %{nodes: nodes, edges: edges}, %{
        kind: "execution",
        terminal_events: length(events),
        runnable_events: length(runnable_events)
      })
    end
  end

  defp graph_source(title, graph, metadata, opts \\ []) do
    %{
      title: title,
      graph: graph,
      mermaid: Keyword.get(opts, :mermaid),
      metadata: metadata,
      invalid?: false
    }
  end

  defp graph_payload(%{graph: graph}), do: field(graph, :graph_summary) || graph

  defp normalize_kind(kind) when kind in ["proposal", "materialized", "execution"], do: kind
  defp normalize_kind(_kind), do: "materialized"

  defp first_kind([%{id: id} | _]), do: id
  defp first_kind(_available), do: "execution"

  defp selected_node_id(id, nodes) when is_binary(id) do
    if Enum.any?(nodes, &(&1.id == id)), do: id, else: nil
  end

  defp selected_node_id(_id, [%{id: id} | _nodes]), do: id
  defp selected_node_id(_id, _nodes), do: nil

  defp selected_node(_nodes, nil, _events), do: nil

  defp selected_node(nodes, id, events) do
    nodes
    |> Enum.find(&(&1.id == id))
    |> case do
      nil -> nil
      node -> Map.put(node, :events, Map.get(events, id, %{}))
    end
  end

  defp node_events(store, run_id) do
    runnable =
      store
      |> Queries.runnable_events(run_id)
      |> Enum.map(fn event ->
        id = event.node_name || event.component_id || event.runnable_id
        {id, %{status: event.status, sequence: event.sequence, stage: event.stage}}
      end)

    terminal =
      store
      |> Queries.terminal_events_for_session(run_id)
      |> Enum.map(fn event ->
        id = event.phase || event.kind
        {id, %{status: event.status, sequence: event.sequence, stage: event.kind}}
      end)

    (runnable ++ terminal)
    |> Enum.reject(fn {id, _event} -> is_nil(id) end)
    |> Map.new()
  end

  defp run_metadata(store, run_id, key) do
    SQLite.with_repo(store, fn ->
      case store.repo.get(RunicAI.Persistence.Schemas.WorkflowRun, run_id) do
        nil -> nil
        run -> field(run.metadata_json || %{}, key)
      end
    end)
  end

  defp artifact_payload(store, run_id, kind) do
    store
    |> Queries.artifacts_for_run(run_id)
    |> Enum.find(&(&1.artifact_kind == kind))
    |> decode_artifact()
  end

  defp decode_artifact(%RunArtifact{artifact_blob: blob}) when is_binary(blob),
    do: Term.from_blob(blob)

  defp decode_artifact(_artifact), do: nil

  defp normalize_nodes(graph) do
    raw_nodes =
      graph
      |> node_values()
      |> Enum.with_index(1)

    raw_nodes
    |> Enum.map(fn {node, index} -> normalize_node(node, index) end)
    |> Kernel.++(implicit_nodes(raw_nodes, graph))
    |> Enum.uniq_by(& &1.id)
  end

  defp node_values(graph) do
    runic = field(graph, :runic) || %{}

    List.wrap(
      field(graph, :nodes) ||
        field(graph, :components) ||
        field(runic, :native_nodes) ||
        []
    )
  end

  defp normalize_node(node, index) when is_map(node) do
    id = field(node, :name) || field(node, :id) || "node_#{index}"

    %{
      id: to_string(id),
      label: to_string(field(node, :label) || field(node, :title) || field(node, :name) || id),
      kind: stringify(field(node, :kind) || field(node, :type)),
      status: stringify(field(node, :status)),
      metadata: node
    }
  end

  defp normalize_node(node, index) do
    id = stringify(node) || "node_#{index}"
    %{id: id, label: id, kind: nil, status: nil, metadata: %{}}
  end

  defp normalize_edges(graph, nodes) do
    node_ids = MapSet.new(nodes, & &1.id)
    runic = field(graph, :runic) || %{}

    explicit =
      (field(graph, :edges) || field(runic, :edgelist))
      |> List.wrap()
      |> Enum.map(&normalize_edge/1)
      |> Enum.reject(&is_nil/1)

    dependencies =
      graph
      |> node_values()
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {node, index} ->
        normalized = normalize_node(node, index)

        node
        |> field(:dependencies)
        |> List.wrap()
        |> Enum.map(&%{from: to_string(&1), to: normalized.id, label: nil})
      end)

    (explicit ++ dependencies)
    |> Enum.filter(&(MapSet.member?(node_ids, &1.from) and MapSet.member?(node_ids, &1.to)))
    |> Enum.uniq_by(&{&1.from, &1.to, &1.label})
  end

  defp normalize_edge(edge) when is_map(edge) do
    from = field(edge, :from) || field(edge, :source)
    to = field(edge, :to) || field(edge, :target)

    if is_nil(from) or is_nil(to) do
      nil
    else
      %{from: to_string(from), to: to_string(to), label: stringify(field(edge, :label))}
    end
  end

  defp normalize_edge(_edge), do: nil

  defp implicit_nodes(raw_nodes, graph) do
    known =
      raw_nodes
      |> Enum.map(fn {node, index} -> normalize_node(node, index).id end)
      |> MapSet.new()

    graph
    |> normalize_edges(Enum.map(raw_nodes, fn {node, index} -> normalize_node(node, index) end))
    |> Enum.flat_map(&[&1.from, &1.to])
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.map(&%{id: &1, label: &1, kind: nil, status: nil, metadata: %{}})
  end

  defp field(nil, _key), do: nil
  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_value, _key), do: nil

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp hash_source(source) do
    :crypto.hash(:sha256, source)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
