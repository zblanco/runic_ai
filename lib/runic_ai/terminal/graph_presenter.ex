defmodule RunicAI.Terminal.GraphPresenter do
  @moduledoc """
  Presentation helpers for normalized workflow graphs.

  The presenter accepts plain maps so terminal renderers can use it for RLM,
  assistant, and standard-agent graph summaries without depending on the
  originating runtime structs.
  """

  @mmdflux_timeout_ms 10_000
  @mmdflux_max_output_bytes 80_000

  @type mode :: :text | :mermaid | :mmdflux

  @spec render(map(), keyword()) :: map()
  def render(graph, opts \\ []) when is_map(graph) do
    mode = Keyword.get(opts, :mode, Keyword.get(opts, :graph, :text))
    graph = graph_source(graph)

    case normalize_mode(mode) do
      :text ->
        %{status: :ok, mode: :text, output: adjacency_text(graph, opts)}

      :mermaid ->
        %{status: :ok, mode: :mermaid, output: serializer_or_mermaid(graph, opts)}

      :mmdflux ->
        render_mmdflux(serializer_or_mermaid(graph, opts), opts)
    end
  end

  @spec render_lines(map(), keyword()) :: [String.t()]
  def render_lines(graph, opts \\ []) when is_map(graph) do
    graph
    |> render(opts)
    |> result_lines()
  end

  @spec adjacency_text(map(), keyword()) :: String.t()
  def adjacency_text(graph, _opts \\ []) when is_map(graph) do
    graph = graph_source(graph)
    graph = normalize_graph(graph)

    header =
      case graph.objective || graph.title do
        nil -> []
        title -> ["objective: #{title}"]
      end

    node_lines =
      Enum.map(graph.nodes, fn node ->
        incoming =
          graph.edges
          |> Enum.filter(&(&1.to == node.id))
          |> Enum.map(&edge_text/1)
          |> Enum.reject(&is_nil/1)

        deps = if incoming == [], do: "root", else: Enum.join(incoming, ", ")
        kind = if node.kind in [nil, ""], do: "node", else: node.kind
        "[#{node.id}] #{kind} <- #{deps}"
      end)

    (header ++ node_lines)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @spec to_mermaid(map(), keyword()) :: String.t()
  def to_mermaid(graph, opts \\ []) when is_map(graph) do
    graph = graph_source(graph)
    graph = normalize_graph(graph)
    direction = opts |> Keyword.get(:direction, graph.direction || "TD") |> to_string()
    id_map = mermaid_id_map(graph.nodes)

    node_lines =
      graph.nodes
      |> Enum.map(fn node ->
        ~s(  #{Map.fetch!(id_map, node.id)}["#{mermaid_label(node)}"])
      end)

    edge_lines =
      graph.edges
      |> Enum.filter(fn edge ->
        Map.has_key?(id_map, edge.from) and Map.has_key?(id_map, edge.to)
      end)
      |> Enum.map(fn edge ->
        from = Map.fetch!(id_map, edge.from)
        to = Map.fetch!(id_map, edge.to)

        case edge.label do
          label when is_binary(label) and label != "" ->
            ~s(  #{from} -- "#{escape_mermaid(label)}" --> #{to})

          _other ->
            "  #{from} --> #{to}"
        end
      end)

    (["flowchart #{direction}"] ++ node_lines ++ edge_lines)
    |> Enum.join("\n")
  end

  defp result_lines(%{status: :ok, output: output}), do: split_output(output)

  defp result_lines(%{status: :pass, output: output}), do: split_output(output)

  defp result_lines(%{status: status, output: output, warning: warning}) do
    ["graph #{status}: #{warning}" | split_output(output)]
  end

  defp result_lines(%{status: status, warning: warning}) do
    ["graph #{status}: #{warning}"]
  end

  defp split_output(output) when is_binary(output) do
    String.split(String.trim_trailing(output), "\n", trim: false)
  end

  defp split_output(_output), do: []

  defp normalize_mode("text"), do: :text
  defp normalize_mode("mermaid"), do: :mermaid
  defp normalize_mode("mmdflux"), do: :mmdflux
  defp normalize_mode(mode) when mode in [:text, :mermaid, :mmdflux], do: mode
  defp normalize_mode(_mode), do: :text

  defp graph_source(graph) do
    field(graph, :graph_summary) || graph
  end

  defp serializer_or_mermaid(graph, opts) do
    graph
    |> serializer(:mermaid)
    |> case do
      source when is_binary(source) and source != "" -> source
      _other -> to_mermaid(graph, opts)
    end
  end

  defp serializer(graph, name) do
    graph
    |> field(:runic)
    |> field(:serializers)
    |> field(name)
  end

  defp normalize_graph(graph) do
    graph = field(graph, :graph) || graph
    runic = field(graph, :runic) || %{}

    raw_nodes =
      List.wrap(
        field(graph, :nodes) ||
          field(graph, :components) ||
          field(runic, :native_nodes) ||
          []
      )

    nodes =
      raw_nodes
      |> Enum.with_index(1)
      |> Enum.map(fn {node, index} -> normalize_node(node, index) end)

    edges =
      (field(graph, :edges) || field(runic, :edgelist))
      |> List.wrap()
      |> Enum.map(&normalize_edge/1)
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(dependency_edges(nodes, raw_nodes))
      |> Enum.uniq_by(&{&1.from, &1.to, &1.label})

    nodes =
      nodes
      |> Kernel.++(implicit_nodes(nodes, edges))
      |> Enum.uniq_by(& &1.id)

    %{
      title: field(graph, :title) || field(graph, :id),
      objective: field(graph, :objective),
      direction: field(graph, :direction),
      nodes: nodes,
      edges: edges
    }
  end

  defp normalize_node(node, index) when is_map(node) do
    id = field(node, :name) || field(node, :id) || "node_#{index}"

    %{
      id: to_string(id),
      label: field(node, :label) || field(node, :title) || field(node, :name) || id,
      kind: stringify(field(node, :kind) || field(node, :type)),
      status: stringify(field(node, :status)),
      dependencies: dependencies(node)
    }
  end

  defp normalize_node(node, index) do
    %{
      id: stringify(node) || "node_#{index}",
      label: stringify(node) || "node_#{index}",
      kind: nil,
      status: nil,
      dependencies: []
    }
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

  defp dependency_edges(nodes, raw_nodes) do
    nodes
    |> Enum.zip(raw_nodes)
    |> Enum.flat_map(fn {node, raw_node} ->
      raw_node
      |> dependencies()
      |> Enum.map(&%{from: to_string(&1), to: node.id, label: nil})
    end)
  end

  defp dependencies(node) when is_map(node) do
    node
    |> field(:dependencies)
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp dependencies(_node), do: []

  defp implicit_nodes(nodes, edges) do
    node_ids = MapSet.new(nodes, & &1.id)

    edges
    |> Enum.flat_map(&[&1.from, &1.to])
    |> Enum.reject(&MapSet.member?(node_ids, &1))
    |> Enum.map(&%{id: &1, label: &1, kind: nil, status: nil, dependencies: []})
  end

  defp mermaid_id_map(nodes) do
    nodes
    |> Enum.with_index(1)
    |> Map.new(fn {node, index} -> {node.id, "n#{index}"} end)
  end

  defp mermaid_label(node) do
    [node.label || node.id, node.kind && "(#{node.kind})", node.status && "[#{node.status}]"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\\n")
    |> escape_mermaid()
  end

  defp edge_text(%{from: from, label: label}) when is_binary(label) and label != "",
    do: "#{from} (#{label})"

  defp edge_text(%{from: from}), do: from
  defp edge_text(_edge), do: nil

  defp render_mmdflux(source, opts) do
    case System.find_executable("mmdflux") do
      nil ->
        %{
          status: :blocked,
          mode: :mmdflux,
          output: source,
          warning: "mmdflux executable was not found on PATH"
        }

      executable ->
        execute_mmdflux(executable, source, opts)
    end
  end

  defp execute_mmdflux(executable, source, opts) do
    args = ["--format", "text", "--color", mmdflux_color(Keyword.get(opts, :color, :auto))]

    tmp_path =
      Path.join(System.tmp_dir!(), "runic-ai-graph-#{System.unique_integer([:positive])}.mmd")

    try do
      task =
        Task.async(fn ->
          File.write!(tmp_path, source)
          System.cmd(executable, args ++ [tmp_path], stderr_to_stdout: true)
        end)

      case Task.yield(task, @mmdflux_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} ->
          %{status: :pass, mode: :mmdflux, output: truncate(output)}

        {:ok, {output, exit_status}} ->
          %{
            status: :fail,
            mode: :mmdflux,
            output: truncate(output),
            warning: "mmdflux exited with status #{exit_status}"
          }

        {:exit, reason} ->
          %{
            status: :fail,
            mode: :mmdflux,
            output: source,
            warning: "mmdflux exited: #{inspect(reason)}"
          }

        nil ->
          %{
            status: :fail,
            mode: :mmdflux,
            output: source,
            warning: "mmdflux timed out after #{@mmdflux_timeout_ms}ms"
          }
      end
    after
      File.rm(tmp_path)
    end
  end

  defp mmdflux_color(:always), do: "always"
  defp mmdflux_color(:never), do: "off"
  defp mmdflux_color("always"), do: "always"
  defp mmdflux_color("never"), do: "off"
  defp mmdflux_color("off"), do: "off"
  defp mmdflux_color(_color), do: "auto"

  defp truncate(output) when byte_size(output) <= @mmdflux_max_output_bytes, do: output

  defp truncate(output) do
    output
    |> binary_part(0, @mmdflux_max_output_bytes)
    |> valid_utf8_prefix()
  end

  defp valid_utf8_prefix(output) do
    if String.valid?(output) do
      output
    else
      output
      |> binary_part(0, byte_size(output) - 1)
      |> valid_utf8_prefix()
    end
  end

  defp escape_mermaid(value) do
    value
    |> to_string()
    |> String.replace("\"", "\\\"")
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
