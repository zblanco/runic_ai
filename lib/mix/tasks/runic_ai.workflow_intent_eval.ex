defmodule Mix.Tasks.RunicAi.WorkflowIntentEval do
  use Mix.Task

  @moduledoc """
  Runs one live intent-to-canonical-workflow planning and execution vertical.
  """

  @shortdoc "Runs a live intent-to-workflow vertical"

  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.LLM.ReqLLMClient
  alias RunicAI.LLM.Result
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.WorkflowEvals
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.IntentPlanner

  @switches [model: :string, label: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)
    model = Keyword.get(opts, :model, "openai:gpt-5.6-luna")
    label = Keyword.get(opts, :label, "intent-draft-luna")
    root = Path.join(["tmp", "workflow_intent_evals", label]) |> Path.expand()
    workspace_root = Path.join(root, "workspace")
    database = Path.join(root, "runic_ai.sqlite3")
    report_path = Path.join(root, "report.md")

    seed_workspace(workspace_root)
    {:ok, store} = SQLite.open(database)

    workspace =
      Workspace.new!(
        root: workspace_root,
        path_policy: PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
      )

    {:ok, planning_calls} = Agent.start_link(fn -> [] end)
    {:ok, execution_calls} = Agent.start_link(fn -> [] end)

    objective =
      "Analyze the incident and roadmap notes, then write a delivery risk report with Summary, Risks, and Actions sections that cites the source paths."

    request = %{
      objective: objective,
      input_paths: ["notes/incidents.md", "notes/roadmap.md"],
      output_path: ".docs/delivery-risk-report.md",
      required_sections: ["Summary", "Risks", "Actions"],
      metadata: %{eval_label: label}
    }

    planning_client = tracked_client(planning_calls)
    execution_client = tracked_client(execution_calls)
    started = System.monotonic_time(:millisecond)

    planning =
      IntentPlanner.plan(store, workspace, request,
        strategy: :workflow,
        workflow_key: "delivery-risk-report-#{safe_label(label)}",
        model: model,
        client: planning_client,
        fallback?: false,
        receive_timeout: 120_000,
        llm_opts: [receive_timeout: 120_000, max_completion_tokens: 8_000],
        write_policy: :docs_only,
        require_artifact_quality?: true,
        required_source_cues: ["incidents.md", "roadmap.md"]
      )

    {execution, planned} = execute(planning, workspace, model, execution_client)
    latency_ms = System.monotonic_time(:millisecond) - started
    planning_usage = usage_totals(Agent.get(planning_calls, & &1))
    execution_usage = usage_totals(Agent.get(execution_calls, & &1))
    verified? = verified?(planning, execution, workspace_root)

    row = %{
      case_id: label,
      rows: [
        %{
          arm: :intent_draft,
          status: if(verified?, do: :pass, else: :fail),
          metrics: %{
            verified_success: verified?,
            latency_ms: latency_ms,
            planning_usage: planning_usage,
            execution_usage: execution_usage,
            total_tokens:
              value(planning_usage, :total_tokens, 0) + value(execution_usage, :total_tokens, 0),
            node_count: if(planned, do: map_size(planned.ir.nodes), else: 0),
            edge_count: if(planned, do: map_size(planned.ir.edges), else: 0)
          },
          diagnostics: diagnostics(planning, execution),
          artifacts: artifacts(planning, execution, workspace_root)
        }
      ]
    }

    {:ok, _records} =
      WorkflowEvals.record_case(store, row,
        suite: label,
        task_family: "intent_to_workflow",
        model: model
      )

    File.mkdir_p!(root)
    File.write!(report_path, report(model, label, planning, execution, row.rows |> hd()))
    SQLite.close(store)
    Mix.shell().info("wrote #{Path.relative_to_cwd(report_path)}")

    unless verified? do
      Mix.raise("intent-to-workflow vertical did not verify; inspect #{report_path}")
    end
  end

  defp execute({:ok, %{status: :drafted} = planned}, workspace, model, client) do
    execution =
      Compiler.run(planned.ir, workspace, %{},
        model: model,
        client: client,
        receive_timeout: 120_000,
        async: true,
        timeout: 180_000
      )

    {execution, planned}
  end

  defp execute(planning, _workspace, _model, _client),
    do: {{:error, :planning_failed}, planned(planning)}

  defp planned({:ok, %{status: :drafted} = planned}), do: planned
  defp planned(_planning), do: nil

  defp verified?({:ok, %{status: :drafted}}, {:ok, result}, workspace_root) do
    report_path = Path.join(workspace_root, ".docs/delivery-risk-report.md")

    File.exists?(report_path) and
      get_in(result, [:scorecard, :objective_status]) == :objective_satisfied
  end

  defp verified?(_planning, _execution, _workspace_root), do: false

  defp tracked_client(agent) do
    fn model, prompt, opts ->
      started = System.monotonic_time(:millisecond)
      outcome = ReqLLMClient.generate_text(model, prompt, opts)

      call = %{
        model: model,
        prompt_bytes: prompt |> to_string() |> byte_size(),
        latency_ms: System.monotonic_time(:millisecond) - started,
        usage: outcome_usage(outcome),
        status: if(match?({:ok, %Result{}}, outcome), do: :ok, else: :error)
      }

      Agent.update(agent, &[call | &1])
      outcome
    end
  end

  defp outcome_usage({:ok, %Result{usage: usage}}), do: usage
  defp outcome_usage(_outcome), do: %{}

  defp usage_totals(calls) do
    calls
    |> Enum.flat_map(&Map.to_list(&1.usage || %{}))
    |> Enum.reduce(%{calls: length(calls)}, fn
      {key, amount}, acc when is_number(amount) -> Map.update(acc, key, amount, &(&1 + amount))
      _entry, acc -> acc
    end)
  end

  defp diagnostics({:error, error}, _execution), do: %{planning_error: inspect(error)}

  defp diagnostics(_planning, {:error, error}), do: %{execution_error: inspect(error)}

  defp diagnostics({:ok, planned}, {:ok, result}) do
    %{
      route: planned.route,
      adapter: planned.adapter_diagnostics,
      repair: planned.repair_history,
      validation: planned.compiled.validation_report,
      scorecard: result.scorecard
    }
  end

  defp artifacts({:ok, planned}, execution, workspace_root) do
    %{
      workflow_key: planned.definition.workflow.workflow_key,
      revision_id: planned.definition.revision.id,
      semantic_hash: planned.definition.revision.semantic_hash,
      compiled_hash: planned.artifact.compiled_hash,
      ir: planned.ir,
      execution: execution_summary(execution),
      report_path: Path.join(workspace_root, ".docs/delivery-risk-report.md")
    }
  end

  defp artifacts(_planning, execution, workspace_root) do
    %{execution: execution_summary(execution), report_path: workspace_root}
  end

  defp execution_summary({:ok, result}) do
    %{
      output: result.output,
      artifacts: result.artifacts,
      scorecard: result.scorecard,
      execution_metrics: result.execution_metrics
    }
  end

  defp execution_summary({:error, error}), do: %{error: inspect(error)}

  defp report(model, label, planning, execution, row) do
    strategy =
      case planning do
        {:ok, result} -> result.strategy
        _other -> :failed
      end

    definition =
      case planning do
        {:ok, result} -> result.definition.workflow.workflow_key
        _ -> "-"
      end

    metrics = row.metrics

    """
    # Intent-To-Workflow Evaluation

    Label: `#{label}`
    Model: `#{model}`
    Strategy: `#{strategy}`
    Durable definition: `#{definition}`
    Verified: `#{metrics.verified_success}`

    | Planning calls | Execution calls | Total tokens | Nodes | Edges | Latency ms |
    | ---: | ---: | ---: | ---: | ---: | ---: |
    | #{value(metrics.planning_usage, :calls, 0)} | #{value(metrics.execution_usage, :calls, 0)} | #{metrics.total_tokens} | #{metrics.node_count} | #{metrics.edge_count} | #{metrics.latency_ms} |

    Planning outcome: `#{outcome_name(planning)}`
    Execution outcome: `#{outcome_name(execution)}`

    Report artifact: `workspace/.docs/delivery-risk-report.md`
    """
  end

  defp outcome_name({:ok, _result}), do: :ok
  defp outcome_name({:error, error}), do: inspect(error)
  defp outcome_name(other), do: inspect(other)

  defp seed_workspace(root) do
    File.mkdir_p!(Path.join(root, "notes"))
    File.mkdir_p!(Path.join(root, ".docs"))

    File.write!(
      Path.join(root, "notes/incidents.md"),
      "# Incidents\n\nPayment retries caused duplicate work. Add idempotency and alerting.\n"
    )

    File.write!(
      Path.join(root, "notes/roadmap.md"),
      "# Roadmap\n\nThe retry redesign needs an owner and a delivery checkpoint.\n"
    )
  end

  defp safe_label(label), do: String.replace(label, ~r/[^a-zA-Z0-9_-]+/u, "-")

  defp value(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
