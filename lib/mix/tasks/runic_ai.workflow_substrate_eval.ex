defmodule Mix.Tasks.RunicAi.WorkflowSubstrateEval do
  use Mix.Task

  @shortdoc "Runs a real-model JSON/DSL/typed-operation workflow bake-off"

  alias RunicAI.Persistence.WorkflowEvals
  alias RunicAI.Workbench
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.SubstrateLLMEval

  @switches [model: :string, label: :string, case: :string, repetitions: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)
    model = Keyword.get(opts, :model, "openai:gpt-5.6-luna")
    label = Keyword.get(opts, :label, "workflow-substrate-live")
    repetitions = max(Keyword.get(opts, :repetitions, 1), 1)
    selected_case = Keyword.get(opts, :case, "all")

    fixtures =
      fixtures()
      |> Enum.filter(&(selected_case == "all" or &1.id == selected_case))

    if fixtures == [] do
      Mix.raise(
        "unknown --case #{inspect(selected_case)}; expected all or one of #{inspect(Enum.map(fixtures(), & &1.id))}"
      )
    end

    results =
      for fixture <- fixtures, repetition <- 1..repetitions do
        eval_case = %{
          id: "#{fixture.id}/r#{repetition}",
          instruction: fixture.instruction,
          base_ir: fixture.base,
          target_ir: fixture.target
        }

        {:ok, result} = SubstrateLLMEval.run_case(eval_case, model: model)

        {:ok, _rows} =
          WorkflowEvals.record_case(Workbench.store!(), result,
            suite: label,
            task_family: fixture.task_family,
            model: model
          )

        Map.merge(result, %{
          fixture_id: fixture.id,
          task_family: fixture.task_family,
          graph_nodes: map_size(fixture.base.nodes),
          expected_operations: fixture.operations
        })
      end

    path = Path.join("tmp/workflow_substrate_evals", "#{label}.md")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, report(results, model))
    Mix.shell().info("wrote #{path}")
  end

  defp fixtures do
    [
      local_edit_fixture(
        "tiny-policy",
        "research",
        1,
        "Set workflow policy max_runtime_ms to 5000 and change nothing else.",
        [%{op: "set_policy", key: "max_runtime_ms", value: 5_000}]
      ),
      local_edit_fixture(
        "medium-argument",
        "coding",
        6,
        "Set argument operation on node step_3 to normalize and change nothing else.",
        [%{op: "set_argument", node_id: "step_3", key: "operation", value: "normalize"}]
      ),
      local_edit_fixture(
        "large-annotation",
        "bounded_batch",
        14,
        "Annotate node step_8 with rationale human review checkpoint and change nothing else.",
        [
          %{
            op: "annotate",
            node_id: "step_8",
            key: "rationale",
            value: "human review checkpoint"
          }
        ]
      )
    ]
  end

  defp local_edit_fixture(id, task_family, node_count, instruction, operations) do
    nodes =
      1..node_count
      |> Enum.map(fn index ->
        node_id = "step_#{index}"

        {:ok, node} =
          Node.new(node_id, :blueprint_transform,
            arguments: %{"operation" => "identity", "ordinal" => index},
            metadata: %{"label" => "Stage #{index}"}
          )

        {node_id, node}
      end)
      |> Map.new()

    edges =
      if node_count > 1 do
        1..(node_count - 1)
        |> Enum.map(fn index ->
          {:ok, edge} =
            Edge.new(
              %{node: "step_#{index}", port: "out"},
              %{node: "step_#{index + 1}", port: "in"}
            )

          {edge.id, edge}
        end)
        |> Map.new()
      else
        %{}
      end

    {:ok, base} =
      IR.new("workflow:substrate-#{id}", "Measure local repair at #{node_count} nodes",
        nodes: nodes,
        edges: edges,
        acceptance: [%{"id" => "unchanged-output", "required" => true}],
        policies: %{"max_concurrency" => 2}
      )

    {:ok, edited} =
      Editor.apply(base, %{
        base_revision: base.revision,
        base_hash: IR.semantic_hash(base),
        operations: operations
      })

    %{
      id: id,
      task_family: task_family,
      instruction: instruction,
      base: base,
      target: edited.ir,
      operations: operations
    }
  end

  defp report(results, model) do
    rows =
      Enum.map_join(results, "\n", fn result ->
        Enum.map_join(result.rows, "\n", fn row ->
          usage = row.metrics.provider_usage || %{}

          "| #{result.case_id} | #{result.graph_nodes} | #{row.arm} | #{row.status} | #{value(usage, :input_tokens)} | #{value(usage, :output_tokens)} | #{row.metrics.latency_ms} | #{row.metrics.prompt_bytes} | #{row.metrics.response_bytes} |"
        end)
      end)

    summaries =
      [:normalized_json, :compact_dsl, :typed_operations]
      |> Enum.map_join("\n", fn arm ->
        arm_rows = for result <- results, row <- result.rows, row.arm == arm, do: row
        passes = Enum.count(arm_rows, &(&1.status == :pass))
        input_tokens = Enum.sum(Enum.map(arm_rows, &usage_number(&1, :input_tokens)))
        output_tokens = Enum.sum(Enum.map(arm_rows, &usage_number(&1, :output_tokens)))
        latency_ms = Enum.sum(Enum.map(arm_rows, & &1.metrics.latency_ms))

        "| #{arm} | #{passes}/#{length(arm_rows)} | #{input_tokens} | #{output_tokens} | #{input_tokens + output_tokens} | #{latency_ms} |"
      end)

    case_notes =
      Enum.map_join(results, "\n", fn result ->
        "- `#{result.case_id}` (#{result.graph_nodes} nodes, #{result.task_family}): `#{Jason.encode!(result.expected_operations)}`"
      end)

    """
    # Workflow Substrate Live Evaluation Suite

    Model: `#{model}`

    ## Aggregate

    | Arm | Semantic passes | Input tokens | Output tokens | Total tokens | Latency ms |
    | --- | ---: | ---: | ---: | ---: | ---: |
    #{summaries}

    ## Cases

    #{case_notes}

    ## Runs

    | Case | Nodes | Arm | Status | Input tokens | Output tokens | Latency ms | Prompt bytes | Response bytes |
    | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
    #{rows}

    All semantic checks passed: `#{Enum.all?(results, & &1.all_pass?)}`
    Provider usage complete: `#{Enum.all?(results, & &1.provider_usage_complete?)}`
    """
  end

  defp usage_number(row, key) do
    row.metrics.provider_usage
    |> Kernel.||(%{})
    |> value(key)
    |> case do
      number when is_number(number) -> number
      _missing -> 0
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), "-"))
end
