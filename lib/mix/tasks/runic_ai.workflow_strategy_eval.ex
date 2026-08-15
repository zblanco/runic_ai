defmodule Mix.Tasks.RunicAi.WorkflowStrategyEval do
  use Mix.Task

  @moduledoc """
  Runs and retains a live direct/reuse/adapt/draft strategy comparison.
  """

  @shortdoc "Compares live workflow intent strategies"

  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Agent, as: CodingAgent
  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.ReqLLMClient
  alias RunicAI.LLM.Result
  alias RunicAI.Message
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.WorkflowEvals
  alias RunicAI.Workflows.IntentStrategyComparator

  @switches [model: :string, label: :string, family: :string, scenario: :string]
  @families ["research", "batch", "coding"]
  @scenarios ["default", "novel"]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)
    model = Keyword.get(opts, :model, "openai:gpt-5.6-luna")
    family = Keyword.get(opts, :family, "research")
    scenario = Keyword.get(opts, :scenario, "default")
    validate_family!(family)
    validate_scenario!(scenario)

    label =
      Keyword.get(opts, :label, "065-intent-strategy-#{family}-#{scenario}-luna")

    root = Path.join(["tmp", "workflow_strategy_evals", label]) |> Path.expand()
    database = Path.join(root, "runic_ai.sqlite3")
    report_path = Path.join(root, "report.md")
    workspaces = provision_workspaces(root, family)
    {:ok, store} = SQLite.open(database)

    comparator_opts =
      [
        base_workspace: workspaces.base,
        workspace_for: %{
          direct_agent: workspaces.direct_agent,
          adapt: workspaces.adapt,
          draft: workspaces.draft
        },
        model: model,
        client: ReqLLMClient,
        base_client: base_client(family),
        direct_agent: direct_agent(family),
        write_policy: :docs_only,
        receive_timeout: 120_000,
        llm_opts: [receive_timeout: 120_000, max_completion_tokens: 8_000]
      ] ++ family_comparator_opts(family)

    result =
      IntentStrategyComparator.run_case(store, eval_case(family, scenario), comparator_opts)

    case result do
      {:ok, comparison} ->
        {:ok, _records} =
          WorkflowEvals.record_case(store, comparison,
            suite: label,
            task_family: comparison.task_family,
            model: model
          )

        File.write!(report_path, report(label, model, comparison))
        SQLite.close(store)
        Mix.shell().info("wrote #{Path.relative_to_cwd(report_path)}")

        unless comparison.all_pass? do
          Mix.raise("intent strategy comparison did not pass; inspect #{report_path}")
        end

      {:error, error} ->
        File.write!(report_path, failure_report(label, model, error))
        SQLite.close(store)
        Mix.raise("intent strategy comparison failed to initialize; inspect #{report_path}")
    end
  end

  defp validate_family!(family) when family in @families, do: :ok

  defp validate_family!(family) do
    Mix.raise(
      "unknown workflow strategy family #{inspect(family)}; expected one of #{inspect(@families)}"
    )
  end

  defp validate_scenario!(scenario) when scenario in @scenarios, do: :ok

  defp validate_scenario!(scenario) do
    Mix.raise(
      "unknown workflow strategy scenario #{inspect(scenario)}; expected one of #{inspect(@scenarios)}"
    )
  end

  defp provision_workspaces(root, family) do
    File.mkdir_p!(root)

    Map.new([:base, :direct_agent, :adapt, :draft], fn arm ->
      workspace_root = Path.join(root, "workspace-#{arm}")
      File.mkdir_p!(Path.join(workspace_root, ".docs"))
      seed_family_workspace(workspace_root, family)

      workspace =
        Workspace.new!(
          root: workspace_root,
          path_policy:
            PathPolicy.new!(
              hidden_policy: :allow,
              allowed_write_roots: workspace_write_roots(family)
            )
        )

      {arm, workspace}
    end)
  end

  defp seed_family_workspace(workspace_root, "research") do
    File.mkdir_p!(Path.join(workspace_root, "notes"))

    File.write!(
      Path.join(workspace_root, "notes/incidents.md"),
      """
      # Delivery incidents

      Payment retry handling caused duplicate work. Remediation calls for
      idempotency and alerting, but no accountable owner or acceptance criteria
      are recorded.
      """
    )

    File.write!(
      Path.join(workspace_root, "notes/roadmap.md"),
      """
      # Delivery roadmap

      The retry redesign is planned before the next payment milestone. The plan
      has no dated checkpoint and does not say whether it closes the incident.
      """
    )
  end

  defp seed_family_workspace(workspace_root, "batch") do
    File.mkdir_p!(Path.join(workspace_root, "data"))

    File.write!(
      Path.join(workspace_root, "data/work-items.csv"),
      "id,team,status\n1,api,ready\n2,web,blocked\n3,api,ready\n4,ops,review\n"
    )
  end

  defp seed_family_workspace(workspace_root, "coding") do
    File.mkdir_p!(Path.join(workspace_root, "lib"))

    File.write!(
      Path.join(workspace_root, "mix.exs"),
      """
      defmodule WorkflowStrategyCodingFixture.MixProject do
        use Mix.Project
        def project, do: [app: :workflow_strategy_coding_fixture, version: "0.1.0"]
      end
      """
    )

    File.write!(
      Path.join(workspace_root, "lib/demo.ex"),
      "defmodule Demo do\n  def answer, do: 42\nend\n"
    )
  end

  defp workspace_write_roots("coding"), do: [".docs", "lib", "test"]
  defp workspace_write_roots(_family), do: [".docs"]

  defp base_client("research") do
    fn _model, _prompt, _opts ->
      {:ok,
       Result.new!(
         Message.new!(
           :assistant,
           """
           ## Summary
           Payment retries caused duplicate work according to notes/incidents.md,
           while notes/roadmap.md leaves the remediation checkpoint undated.

           ## Risks
           Retry behavior can repeat work.

           ## Actions
           Validate idempotency and alerting.
           """
         ),
         finish_reason: :stop,
         usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
       )}
    end
  end

  defp base_client("batch") do
    fn _model, _prompt, _opts ->
      {:ok,
       Result.new!(
         Message.new!(:assistant, "deterministic batch fixture does not call the model"),
         finish_reason: :stop,
         usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
       )}
    end
  end

  defp base_client("coding"), do: base_client("batch")

  defp direct_agent(family) do
    fn workspace, request, model, client ->
      workflow =
        CodingAgent.patch(workspace, direct_agent_task(family, request),
          model: model,
          client: client,
          max_turns: 12,
          # Comparator workspaces are isolated and already enforce the same
          # bounded write roots as workflow execution. A review wait here would
          # handicap only the direct-agent control rather than compare ability.
          review_gates?: false
        )

      {:ok, CodingAgent.summary(workflow)}
    end
  end

  defp direct_agent_task("research", request) do
    """
    #{request.objective}

    Inspect only these workspace-relative sources: #{Enum.join(request.input_paths, ", ")}.
    Write the result to #{request.output_path} with these Markdown headings:
    #{Enum.join(request.required_sections, ", ")}.
    Ground the report in the source filenames and use apply_patch to create the artifact.
    """
  end

  defp direct_agent_task("batch", request) do
    """
    #{request.objective}

    Read #{Enum.join(request.input_paths, ", ")}. Preserve every input record ID exactly once
    in a concise Markdown table under the #{Enum.join(request.required_sections, ", ")}
    heading. Write the complete artifact to #{request.output_path} with apply_patch.
    """
  end

  defp direct_agent_task("coding", request) do
    metadata = request.metadata

    """
    #{request.objective}

    Inspect #{Enum.join(request.input_paths, ", ")}, make the smallest valid Elixir source
    edit under lib/, and use apply_patch. Preserve existing behavior. The final workspace
    must contain #{metadata.module} with `#{metadata.expected}` returning
    `#{metadata.return_source}`.
    """
  end

  defp family_comparator_opts("coding") do
    validation_opts = [allow_mutation?: true, allow_verification?: true]

    [
      dialect: :coding,
      base_coding_proposal: coding_proposal(coding_base_request()),
      coding_opts: [
        validation_opts: validation_opts,
        fallback?: false,
        proposal_repair_attempts: 2
      ],
      compile_opts: [validation_opts: validation_opts],
      execution_opts: [validation_opts: validation_opts, async: false]
    ]
  end

  defp family_comparator_opts(_family), do: []

  defp eval_case("research", scenario) do
    target_request = research_target_request(scenario)

    %{
      id: "research-direct-adapt-draft-#{scenario}",
      task_family: "research_and_cited_synthesis",
      base_workflow_key: "delivery-risk-report-proven",
      adapted_workflow_key: "#{scenario}-research-adapted",
      drafted_workflow_key: "#{scenario}-research-drafted",
      direct_request: %{objective: "Explain what idempotency means"},
      base_request: base_request(),
      target_request: target_request,
      negative_request: %{
        objective: target_request.objective,
        input: %{},
        input_paths: [42],
        output_path: target_request.output_path,
        required_sections: target_request.required_sections
      },
      base_blueprint: base_blueprint()
    }
  end

  defp eval_case("batch", scenario) do
    target_request = batch_target_request(scenario)

    %{
      id: "batch-direct-adapt-draft-held-out-#{scenario}",
      task_family: "bounded_batch_transformation",
      base_workflow_key: "work-item-status-batch-proven",
      adapted_workflow_key: "#{scenario}-batch-adapted",
      drafted_workflow_key: "#{scenario}-batch-drafted",
      direct_request: %{objective: "What does CSV stand for?"},
      base_request: batch_base_request(),
      target_request: target_request,
      negative_request: %{
        objective: target_request.objective,
        input: %{},
        input_paths: [42],
        output_path: target_request.output_path,
        required_sections: target_request.required_sections
      },
      base_blueprint: batch_blueprint(batch_base_request()),
      verify: &verify_batch/3
    }
  end

  defp eval_case("coding", scenario) do
    target_request = coding_target_request(scenario)

    %{
      id: "coding-direct-adapt-draft-held-out-#{scenario}",
      task_family: "repository_change_and_verification",
      base_workflow_key: "add-demo-label-proven",
      adapted_workflow_key: "#{scenario}-coding-adapted",
      drafted_workflow_key: "#{scenario}-coding-drafted",
      direct_request: %{objective: "Explain what an Elixir module is"},
      base_request: coding_base_request(),
      target_request: target_request,
      negative_request: %{
        objective: target_request.objective,
        input: %{},
        input_paths: [42],
        metadata: target_request.metadata
      },
      verify: &verify_coding/3
    }
  end

  defp base_request do
    %{
      objective: "Analyze incident roadmap notes and write a delivery risk report",
      input: %{},
      input_paths: ["notes/incidents.md", "notes/roadmap.md"],
      output_path: ".docs/delivery-risk.md",
      required_sections: ["Summary", "Risks", "Actions"],
      metadata: %{eval_role: "proven_base"}
    }
  end

  defp research_target_request("default") do
    %{
      objective: "Analyze incident roadmap notes and write an operational readiness report",
      input: %{},
      input_paths: ["notes/incidents.md", "notes/roadmap.md"],
      output_path: ".docs/operational-readiness.md",
      required_sections: ["Summary", "Gaps", "Actions"],
      metadata: %{eval_role: "comparison_target"}
    }
  end

  defp research_target_request("novel") do
    %{
      objective:
        "Analyze incident and roadmap evidence, decide whether the payment milestone should proceed, and write a go-or-hold decision memo",
      input: %{},
      input_paths: ["notes/incidents.md", "notes/roadmap.md"],
      output_path: ".docs/payment-milestone-decision.md",
      required_sections: ["Evidence", "Decision", "Follow-ups"],
      metadata: %{eval_role: "novel_comparison_target"}
    }
  end

  defp base_blueprint do
    request = base_request()

    %{
      id: "workflow:delivery-risk-report-proven",
      objective: request.objective,
      sources: [
        %{id: "incidents", path: "notes/incidents.md"},
        %{id: "roadmap", path: "notes/roadmap.md"}
      ],
      components: [
        %{
          id: "split",
          type: "source_splitter",
          params: %{paths: request.input_paths, strategy: "markdown_heading", max_bytes: 8_000}
        },
        %{id: "materialize", type: "source_materializer", params: %{}},
        %{
          id: "analyze",
          type: "llm_map",
          params: %{
            prompt:
              "Write a concise delivery risk report with Summary, Risks, and Actions from {{text}}. Preserve source paths."
          }
        },
        %{id: "join", type: "lambda_reduce", params: %{strategy: "join"}},
        %{id: "write", type: "artifact_writer", params: %{path: request.output_path}},
        %{
          id: "score",
          type: "objective_scorecard",
          params: %{
            artifact_path: request.output_path,
            required_sections: request.required_sections,
            required_source_cues: ["incidents.md", "roadmap.md"]
          }
        }
      ],
      edges: [
        %{from: "split", output: "out", to: "materialize", input: "in"},
        %{from: "materialize", output: "out", to: "analyze", input: "in"},
        %{from: "analyze", output: "out", to: "join", input: "in"},
        %{from: "join", output: "out", to: "write", input: "in"},
        %{from: "write", output: "out", to: "score", input: "in"}
      ],
      stop_conditions: ["artifact written", "objective scorecard satisfied"],
      policies: %{max_concurrency: 2, max_runtime_ms: 180_000},
      metadata: %{proposal_kind: "proven_research_fixture"}
    }
  end

  defp batch_base_request do
    %{
      objective: "Transform bounded work item CSV rows and write a status summary",
      input: %{},
      input_paths: ["data/work-items.csv"],
      output_path: ".docs/work-item-status-summary.md",
      required_sections: ["Transformed Records"],
      metadata: %{eval_role: "proven_base"}
    }
  end

  defp batch_target_request("default") do
    %{
      objective: "Transform work item CSV rows and write an operational work queue",
      input: %{},
      input_paths: ["data/work-items.csv"],
      output_path: ".docs/operational-work-queue.md",
      required_sections: ["Normalized Work Items"],
      metadata: %{eval_role: "held_out_comparison_target"}
    }
  end

  defp batch_target_request("novel") do
    %{
      objective:
        "Transform bounded work item CSV rows into a team ownership index while preserving every record",
      input: %{},
      input_paths: ["data/work-items.csv"],
      output_path: ".docs/team-ownership-index.md",
      required_sections: ["Ownership Index"],
      metadata: %{eval_role: "novel_comparison_target"}
    }
  end

  defp batch_blueprint(request) do
    %{
      id: "workflow:bounded-work-item-batch",
      objective: request.objective,
      sources: Enum.map(request.input_paths, &%{id: Path.basename(&1), path: &1}),
      components: [
        %{
          id: "split",
          type: "source_splitter",
          params: %{paths: request.input_paths, max_bytes: 16_000, max_chunks: 1}
        },
        %{id: "materialize", type: "source_materializer", params: %{}},
        %{id: "parse", type: "tabular_parser", params: %{format: "csv"}},
        %{
          id: "transform_each",
          type: "record_map",
          params: %{
            max_items: 10,
            max_concurrency: 4,
            function: %{
              tier: "tier1",
              expr: %{
                op: "template",
                template: "id={{id}} team={{team}} status={{status}}",
                from: %{op: "input"}
              }
            }
          }
        },
        %{id: "aggregate", type: "lambda_reduce", params: %{strategy: "join"}},
        %{
          id: "compose",
          type: "lambda_generate",
          params: %{title: "Work Item Status Summary", sections: request.required_sections}
        },
        %{id: "write", type: "artifact_writer", params: %{path: request.output_path}},
        %{
          id: "verify",
          type: "objective_scorecard",
          params: %{
            artifact_path: request.output_path,
            required_sections: request.required_sections
          }
        }
      ],
      edges: [
        %{from: "split", output: "out", to: "materialize", input: "in"},
        %{from: "materialize", output: "out", to: "parse", input: "in"},
        %{from: "parse", output: "out", to: "transform_each", input: "in"},
        %{from: "transform_each", output: "out", to: "aggregate", input: "in"},
        %{from: "aggregate", output: "out", to: "compose", input: "in"},
        %{from: "compose", output: "out", to: "write", input: "in"},
        %{from: "write", output: "out", to: "verify", input: "in"}
      ],
      stop_conditions: ["all bounded records transformed", "summary artifact verified"],
      policies: %{max_concurrency: 4, max_items: 10},
      metadata: %{proposal_kind: "bounded_batch_strategy_fixture"}
    }
  end

  defp verify_batch(execution, workspace, request) do
    path = Path.join(workspace.root, request.output_path)

    with true <-
           direct_agent_execution?(execution) or
             get_in(execution, [:scorecard, :objective_status]) == :objective_satisfied,
         :ok <- verify_batch_artifact(path, request.required_sections) do
      :ok
    else
      other -> {:error, {:batch_proof_failed, other}}
    end
  end

  @doc false
  def verify_batch_artifact(path, required_sections, record_ids \\ ["1", "2", "3", "4"])
      when is_binary(path) and is_list(required_sections) and is_list(record_ids) do
    with true <- File.regular?(path),
         body <- File.read!(path),
         true <- Enum.all?(required_sections, &markdown_heading?(body, &1)),
         true <- Enum.all?(record_ids, &record_id_present?(body, &1)) do
      :ok
    else
      false -> {:error, :artifact_content_incomplete}
    end
  end

  defp markdown_heading?(body, section) do
    Regex.match?(
      Regex.compile!("^\\s*[#]{1,6}\\s+" <> Regex.escape(section) <> "(?:\\s+[#]+)?\\s*$", "mi"),
      body
    )
  end

  defp record_id_present?(body, id) do
    Regex.match?(
      Regex.compile!(
        "(?:id\\s*[=:]?\\s*`?#{id}`?|work[_ -]?item\\s*[=:]?\\s*`?#{id}`?|record\\s+ID\\s+`?#{id}`?|\\|\\s*`?#{id}`?\\s*\\|)",
        "i"
      ),
      body
    )
  end

  defp coding_base_request do
    %{
      objective: "Add DemoLabel.label/0 returning :ok and verify its source",
      input: %{},
      input_paths: ["lib/demo.ex"],
      metadata: %{
        path: "lib/demo_label.ex",
        module: "DemoLabel",
        function: "label",
        expected: "def label",
        return_source: ":ok"
      }
    }
  end

  defp coding_target_request("default") do
    %{
      objective: "Add DemoStatus.status/0 returning :ok and verify its source",
      input: %{},
      input_paths: ["lib/demo.ex"],
      metadata: %{
        path: "lib/demo_status.ex",
        module: "DemoStatus",
        function: "status",
        expected: "def status",
        return_source: ":ok"
      }
    }
  end

  defp coding_target_request("novel") do
    %{
      objective: "Add DemoHealth.health/0 returning {:ok, 42} and verify its source",
      input: %{},
      input_paths: ["lib/demo.ex"],
      metadata: %{
        path: "lib/demo_health.ex",
        module: "DemoHealth",
        function: "health",
        expected: "def health",
        return_source: "{:ok, 42}"
      }
    }
  end

  defp coding_proposal(request) do
    path = request.metadata.path
    expected = request.metadata.expected
    module = request.metadata.module
    function = request.metadata.function
    return_source = request.metadata.return_source

    %{
      id: "workflow:#{module |> Macro.underscore()}",
      objective: request.objective,
      nodes: [
        %{
          id: "implement",
          kind: "edit",
          params: %{
            operations: [
              %{
                kind: "create_file",
                params: %{
                  path: path,
                  content:
                    "defmodule #{module} do\n  def #{function}, do: #{return_source}\nend\n"
                }
              }
            ]
          }
        },
        %{
          id: "verify",
          kind: "verification_gate",
          params: %{
            checks: [
              %{id: "source", type: "source_contains", params: %{path: path, text: expected}}
            ]
          }
        }
      ],
      edges: [%{from: "implement", to: "verify"}],
      stop_conditions: ["#{path} contains #{expected}"]
    }
  end

  defp verify_coding(execution, workspace, request) do
    module = request.metadata.module
    expected = request.metadata.expected
    return_source = request.metadata.return_source

    matching_paths =
      workspace.root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        body = File.read!(path)

        String.contains?(body, "defmodule #{module}") and
          String.contains?(body, expected) and
          String.contains?(body, return_source)
      end)

    with [_path | _rest] <- matching_paths,
         true <-
           direct_agent_execution?(execution) or
             Enum.any?(
               execution.context.scorecards,
               &(&1.objective_status == :objective_satisfied)
             ) do
      :ok
    else
      other ->
        {:error,
         {:coding_proof_failed, other,
          %{
            preferred_path: request.metadata.path,
            matching_paths: Enum.map(matching_paths, &Path.relative_to(&1, workspace.root))
          }}}
    end
  end

  defp direct_agent_execution?(execution),
    do: Map.get(execution, :evaluation_arm) == :direct_agent

  defp report(label, model, comparison) do
    rows =
      Enum.map_join(comparison.rows, "\n", fn row ->
        metrics = row.metrics

        "| #{row.arm} | #{row.status} | #{metrics.expected_strategy} | #{metrics.actual_strategy} | #{metrics.verified_success} | #{metrics.authoring_calls} | #{metrics.execution_calls} | #{Map.get(metrics, :execution_tool_calls, 0)} | #{metrics.total_tokens} | #{metrics.latency_ms} |"
      end)

    c = comparison.comparison

    target_request =
      comparison.rows
      |> Enum.find(&(&1.arm == :adapt))

    target_path =
      get_in(target_request, [:artifacts, :output_path]) ||
        get_in(target_request, [:artifacts, :request, :metadata, :path]) || "-"

    """
    # Intent Strategy Evaluation

    Label: `#{label}`
    Model: `#{model}`
    Task family: `#{comparison.task_family}`
    All routes and executions passed: `#{comparison.all_pass?}`

    Proven base: `#{comparison.base.workflow_key}@#{comparison.base.revision}`
    Definition hash: `#{comparison.base.definition_hash}`
    Compiled hash: `#{comparison.base.compiled_hash}`

    | Arm | Status | Expected | Actual | Verified | Author calls | Execution calls | Tool calls | Total tokens | Latency ms |
    | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    #{rows}

    ## Adaptation Versus Fresh Draft

    | Both verified | Adapt tokens | Draft tokens | Draft minus adapt | Adapt latency | Draft latency | Draft minus adapt |
    | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    | #{c.both_verified} | #{c.adapt_total_tokens} | #{c.draft_total_tokens} | #{c.token_delta} | #{c.adapt_latency_ms} ms | #{c.draft_latency_ms} ms | #{c.latency_delta_ms} ms |

    ## Direct Agent Product Baseline

    | Verified | Direct tokens | Direct latency | Adapt minus direct tokens | Draft minus direct tokens |
    | ---: | ---: | ---: | ---: | ---: |
    | #{c.direct_agent_verified} | #{c.direct_agent_total_tokens} | #{c.direct_agent_latency_ms} ms | #{c.adapt_minus_direct_tokens} | #{c.draft_minus_direct_tokens} |

    Adapted artifact: `workspace-adapt/#{target_path}`
    Fresh-draft artifact: `workspace-draft/#{target_path}`

    Monetary cost is intentionally omitted while ReqLLM reports the Luna model
    metadata and pricing as unverified. Full prompts, responses, provider usage,
    routing candidates, hashes, and diagnostics are retained in SQLite.
    """
  end

  defp failure_report(label, model, error) do
    """
    # Intent Strategy Evaluation

    Label: `#{label}`
    Model: `#{model}`
    Status: `initialization_error`

    ```text
    #{inspect(error, pretty: true, limit: :infinity)}
    ```
    """
  end
end
