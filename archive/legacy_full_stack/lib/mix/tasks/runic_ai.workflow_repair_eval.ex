defmodule Mix.Tasks.RunicAi.WorkflowRepairEval do
  use Mix.Task

  @shortdoc "Compares whole-object and typed-operation workflow repair"

  alias RunicAI.Coding.Workspace
  alias RunicAI.Persistence.WorkflowEvals
  alias RunicAI.Workbench
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.RepairComparator

  @switches [model: :string, label: :string, case: :string, repetitions: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)
    model = Keyword.get(opts, :model, "openai:gpt-5.6-luna")
    label = Keyword.get(opts, :label, "workflow-repair-live")
    repetitions = max(Keyword.get(opts, :repetitions, 1), 1)
    selected_case = Keyword.get(opts, :case, "all")

    fixtures = Enum.filter(fixtures(), &(selected_case == "all" or &1.id == selected_case))

    if fixtures == [] do
      Mix.raise("unknown --case #{inspect(selected_case)}")
    end

    results =
      for fixture <- fixtures, repetition <- 1..repetitions do
        eval_case = %{fixture | id: "#{fixture.id}/r#{repetition}"}

        {:ok, result} =
          RepairComparator.run_case(eval_case,
            model: model,
            workspace_factory: &workspace/1,
            receive_timeout: 120_000,
            max_completion_tokens: 4_000
          )

        {:ok, _rows} =
          WorkflowEvals.record_case(Workbench.store!(), result,
            suite: label,
            task_family: fixture.task_family,
            model: model
          )

        result
      end

    path = Path.join("tmp/workflow_repair_evals", "#{label}.md")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, report(results, model))
    Mix.shell().info("wrote #{path}")
  end

  defp fixtures do
    [semantic_fixture(), topology_fixture()]
  end

  defp semantic_fixture do
    {base, _edge} = source_ir(%{"max_bytes" => 1})
    operations = [%{op: "set_argument", node_id: "split", key: "max_bytes", value: 100}]
    {:ok, edit} = Editor.apply(base, %{base_revision: 1, operations: operations})

    %{
      id: "semantic-source-limit",
      task_family: "semantic_repair",
      instruction: "Set split.max_bytes to 100 and preserve everything else.",
      base_ir: base,
      target_ir: edit.ir,
      operations: operations
    }
  end

  defp topology_fixture do
    {connected, edge} = source_ir(%{"max_bytes" => 100})
    base = %{connected | edges: %{}}
    operations = [%{op: "connect", edge: edge}]
    {:ok, edit} = Editor.apply(base, %{base_revision: 1, operations: operations})

    %{
      id: "topology-missing-edge",
      task_family: "topology_repair",
      instruction: "Connect split.out to materialize.in and preserve everything else.",
      base_ir: base,
      target_ir: edit.ir,
      operations: operations
    }
  end

  defp source_ir(split_arguments) do
    {:ok, split} =
      Node.new("split", :source_splitter,
        arguments: Map.merge(%{"paths" => ["input.txt"]}, split_arguments)
      )

    {:ok, materialize} = Node.new("materialize", :source_materializer)

    {:ok, edge} =
      Edge.new(%{node: "split", port: "out"}, %{node: "materialize", port: "in"})

    {:ok, ir} =
      IR.new("workflow:repair-comparator", "Materialize a bounded source",
        nodes: %{split.id => split, materialize.id => materialize},
        edges: %{edge.id => edge},
        acceptance: [%{id: "source_materialized", required: true}],
        policies: %{"max_concurrency" => 1}
      )

    {ir, edge}
  end

  defp workspace(arm) do
    root =
      Path.join(
        System.tmp_dir!(),
        "workflow-repair-eval-#{arm}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "input.txt"), "bounded source\n")
    Workspace.new!(root: root)
  end

  defp report(results, model) do
    rows = for result <- results, row <- result.rows, do: row

    summary =
      RepairComparator.arms()
      |> Enum.map_join("\n", fn arm ->
        arm_rows = Enum.filter(rows, &(&1.arm == arm))
        verified = Enum.count(arm_rows, & &1.metrics.verified_success)
        exact = Enum.count(arm_rows, &Map.get(&1.metrics, :exact_semantic_repair, false))

        collateral =
          Enum.sum(Enum.map(arm_rows, &Map.get(&1.metrics, :collateral_change_count, 0)))

        tokens = Enum.sum(Enum.map(arm_rows, &usage(&1, :total_tokens)))
        latency = Enum.sum(Enum.map(arm_rows, & &1.metrics.latency_ms))

        "| #{arm} | #{verified}/#{length(arm_rows)} | #{exact}/#{length(arm_rows)} | #{collateral} | #{tokens} | #{latency} |"
      end)

    details =
      Enum.map_join(rows, "\n", fn row ->
        "| #{row.case_id} | #{row.arm} | #{row.status} | #{row.metrics.verified_success} | #{Map.get(row.metrics, :exact_semantic_repair, false)} | #{Map.get(row.metrics, :collateral_change_count, "-")} | #{Map.get(row.metrics, :missing_change_count, "-")} | #{usage(row, :input_tokens)} | #{usage(row, :output_tokens)} | #{row.metrics.latency_ms} | #{row.metrics.failure_layer || "-"} |"
      end)

    """
    # Workflow Repair End-to-End Evaluation

    Model: `#{model}`

    | Arm | Verified | Exact semantic repair | Collateral changes | Total tokens | Latency ms |
    | --- | ---: | ---: | ---: | ---: | ---: |
    #{summary}

    | Case | Arm | Status | Verified | Exact | Collateral | Missing | Input tokens | Output tokens | Latency ms | Failure layer |
    | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
    #{details}

    All executions verified: `#{Enum.all?(results, & &1.all_verified?)}`
    Typed repair not worse on every case: `#{Enum.all?(results, & &1.typed_not_worse?)}`
    """
  end

  defp usage(row, key) do
    usage = row.metrics.provider_usage || %{}
    Map.get(usage, key, Map.get(usage, Atom.to_string(key), 0)) || 0
  end
end
