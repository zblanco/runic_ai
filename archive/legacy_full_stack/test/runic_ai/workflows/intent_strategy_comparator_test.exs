defmodule RunicAI.Workflows.IntentStrategyComparatorTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Agent, as: CodingAgent
  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.TestClient
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Workflows.IntentStrategyComparator

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "intent-strategy-comparator-#{System.unique_integer([:positive])}"
      )

    workspaces =
      Map.new([:base, :direct_agent, :adapt, :draft], fn arm ->
        arm_root = Path.join(root, Atom.to_string(arm))
        File.mkdir_p!(Path.join(arm_root, "notes"))
        File.mkdir_p!(Path.join(arm_root, ".docs"))
        File.mkdir_p!(Path.join(arm_root, "lib"))

        File.write!(
          Path.join(arm_root, "notes/incidents.md"),
          "# Incidents\n\nPayment retries caused duplicate work.\n"
        )

        File.write!(
          Path.join(arm_root, "mix.exs"),
          """
          defmodule IntentStrategyFixture.MixProject do
            use Mix.Project
            def project, do: [app: :intent_strategy_fixture, version: "0.1.0"]
          end
          """
        )

        File.write!(
          Path.join(arm_root, "lib/demo.ex"),
          "defmodule Demo do\n  def answer, do: 42\nend\n"
        )

        workspace =
          Workspace.new!(
            root: arm_root,
            path_policy:
              PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs", "lib"])
          )

        {arm, workspace}
      end)

    {:ok, store} = SQLite.open(":memory:")

    on_exit(fn ->
      SQLite.close(store)
      File.rm_rf!(root)
    end)

    %{store: store, workspaces: workspaces}
  end

  test "compares direct, exact reuse, structural adaptation, negative selection, and fresh draft",
       %{store: store, workspaces: workspaces} do
    eval_case = eval_case()

    client = fn _model, _prompt, _opts ->
      {:ok,
       TestClient.result("""
       # Summary
       Payment retries caused duplicate work in notes/incidents.md.

       # Risks
       Recurrence remains possible.

       # Gaps
       Ownership is not stated.

       # Actions
       Assign an owner and validate idempotency.
       """)}
    end

    assert {:ok, result} =
             IntentStrategyComparator.run_case(store, eval_case,
               base_workspace: workspaces.base,
               workspace_for: %{
                 direct_agent: workspaces.direct_agent,
                 adapt: workspaces.adapt,
                 draft: workspaces.draft
               },
               model: "test:model",
               client: client,
               draft_blueprint: research_blueprint(target_request()),
               adapt_operations: [
                 %{
                   op: "set_argument",
                   node_id: "write",
                   key: "path",
                   value: ".docs/readiness-report.md"
                 },
                 %{
                   op: "set_argument",
                   node_id: "score",
                   key: "artifact_path",
                   value: ".docs/readiness-report.md"
                 },
                 %{
                   op: "set_argument",
                   node_id: "score",
                   key: "required_sections",
                   value: ["Summary", "Gaps", "Actions"]
                 }
               ]
             )

    assert result.all_pass?
    assert result.base.verified

    rows = Map.new(result.rows, &{&1.arm, &1})
    assert rows.direct.metrics.actual_strategy == :direct
    assert rows.reuse_exact.metrics.actual_strategy == :reuse_exact
    assert rows.negative_selection.metrics.actual_strategy == :draft
    assert rows.adapt.metrics.actual_strategy == :adapt
    assert rows.draft.metrics.actual_strategy == :draft
    assert rows.adapt.metrics.verified_success
    assert rows.draft.metrics.verified_success
    assert rows.adapt.metrics.authoring_calls == 0
    assert rows.draft.metrics.authoring_calls == 0
    assert rows.adapt.artifacts.route.selected.compatible == false
    assert rows.adapt.artifacts.route.selected.adaptable == true
    assert rows.negative_selection.artifacts.route.selected == nil

    assert File.exists?(Path.join(workspaces.adapt.root, ".docs/readiness-report.md"))
    assert File.exists?(Path.join(workspaces.draft.root, ".docs/readiness-report.md"))
  end

  test "compares the same strategies without erasing the coding dialect",
       %{store: store, workspaces: workspaces} do
    validation_opts = [allow_mutation?: true, allow_verification?: true]
    eval_case = coding_eval_case()

    client = fn _model, %RunicAI.Prompt{messages: messages}, _opts ->
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, TestClient.result("Created lib/demo_status.ex with DemoStatus.status/0.")}
      else
        {:ok,
         TestClient.tool_response([
           TestClient.tool_call(
             "apply_patch",
             %{
               operations:
                 Jason.encode!([
                   %{
                     op: "create",
                     path: "lib/demo_status.ex",
                     content: "defmodule DemoStatus do\n  def status, do: :ok\nend\n"
                   }
                 ])
             },
             id: "create_demo_status"
           )
         ])}
      end
    end

    assert {:ok, result} =
             IntentStrategyComparator.run_case(store, eval_case,
               base_workspace: workspaces.base,
               workspace_for: %{
                 direct_agent: workspaces.direct_agent,
                 adapt: workspaces.adapt,
                 draft: workspaces.draft
               },
               model: "test:model",
               client: client,
               direct_agent: fn workspace, request, model, direct_client ->
                 workflow =
                   CodingAgent.patch(workspace, request.objective,
                     model: model,
                     client: direct_client,
                     max_turns: 6
                   )

                 {:ok, CodingAgent.summary(workflow)}
               end,
               dialect: :coding,
               base_coding_proposal: coding_proposal(coding_base_request()),
               draft_coding_proposal: coding_agent_proposal(coding_target_request()),
               coding_opts: [validation_opts: validation_opts],
               compile_opts: [validation_opts: validation_opts],
               execution_opts: [validation_opts: validation_opts, async: false],
               adapt_operations: coding_adaptation_operations()
             )

    assert result.all_pass?
    rows = Map.new(result.rows, &{&1.arm, &1})
    assert rows.direct.metrics.actual_strategy == :direct
    assert rows.direct_agent.metrics.actual_strategy == :direct_agent
    assert rows.reuse_exact.metrics.actual_strategy == :reuse_exact
    assert rows.negative_selection.metrics.actual_strategy == :draft
    assert rows.adapt.metrics.actual_strategy == :adapt
    assert rows.draft.metrics.actual_strategy == :draft
    assert rows.adapt.metrics.verified_success
    assert rows.draft.metrics.verified_success
    assert rows.direct_agent.metrics.verified_success
    assert rows.direct_agent.metrics.execution_calls == 2
    assert rows.direct_agent.metrics.execution_tool_calls == 1
    assert rows.draft.metrics.execution_calls == 2

    assert [first_call, final_call] = rows.draft.artifacts.execution_calls
    assert first_call.finish_reason == :tool_calls
    assert [%{name: "apply_patch"}] = first_call.tool_calls
    assert final_call.finish_reason == :stop
    assert final_call.tool_calls == []

    assert File.read!(Path.join(workspaces.adapt.root, "lib/demo_status.ex")) =~
             "def status"

    assert File.read!(Path.join(workspaces.draft.root, "lib/demo_status.ex")) =~
             "def status"
  end

  defp eval_case do
    %{
      id: "research-route-comparison",
      task_family: "research_and_cited_synthesis",
      base_workflow_key: "delivery-risk-report-base",
      adapted_workflow_key: "operational-readiness-report-adapted",
      drafted_workflow_key: "operational-readiness-report-drafted",
      direct_request: %{objective: "Explain this sentence briefly"},
      base_request: base_request(),
      target_request: target_request(),
      negative_request: %{
        objective: "Analyze incident roadmap notes and write an operational readiness report",
        input: %{},
        input_paths: [42],
        output_path: ".docs/readiness-report.md",
        required_sections: ["Summary", "Gaps", "Actions"]
      },
      base_blueprint: research_blueprint(base_request())
    }
  end

  defp base_request do
    %{
      objective: "Analyze incident roadmap notes and write a delivery risk report",
      input: %{},
      input_paths: ["notes/incidents.md"],
      output_path: ".docs/base-risk-report.md",
      required_sections: ["Summary", "Risks", "Actions"]
    }
  end

  defp target_request do
    %{
      objective: "Analyze incident roadmap notes and write an operational readiness report",
      input: %{},
      input_paths: ["notes/incidents.md"],
      output_path: ".docs/readiness-report.md",
      required_sections: ["Summary", "Gaps", "Actions"]
    }
  end

  defp research_blueprint(request) do
    %{
      id: "workflow:#{Path.basename(request.output_path, ".md")}",
      objective: request.objective,
      sources: [%{id: "incidents", path: "notes/incidents.md"}],
      components: [
        %{
          id: "split",
          type: "source_splitter",
          params: %{paths: request.input_paths, strategy: "markdown_heading", max_bytes: 8_000}
        },
        %{id: "materialize", type: "source_materializer", params: %{}},
        %{
          id: "extract",
          type: "llm_map",
          params: %{prompt: "Extract grounded evidence from {{text}}"}
        },
        %{id: "join", type: "lambda_reduce", params: %{strategy: "join"}},
        %{
          id: "synthesize",
          type: "llm_leaf",
          params: %{
            strategy: "llm_reduce",
            group_prompt: "Preserve this evidence: {{items}}",
            prompt: "Write the requested report from {{items}}"
          }
        },
        %{id: "write", type: "artifact_writer", params: %{path: request.output_path}},
        %{
          id: "score",
          type: "objective_scorecard",
          params: %{
            artifact_path: request.output_path,
            required_sections: request.required_sections
          }
        }
      ],
      edges: [
        %{from: "split", output: "out", to: "materialize", input: "in"},
        %{from: "materialize", output: "out", to: "extract", input: "in"},
        %{from: "extract", output: "out", to: "join", input: "in"},
        %{from: "join", output: "out", to: "synthesize", input: "in"},
        %{from: "synthesize", output: "out", to: "write", input: "in"},
        %{from: "write", output: "out", to: "score", input: "in"}
      ],
      stop_conditions: ["artifact written", "objective scorecard satisfied"],
      policies: %{max_concurrency: 2},
      metadata: %{proposal_kind: "intent_strategy_comparator_fixture"}
    }
  end

  defp coding_eval_case do
    %{
      id: "coding-route-comparison",
      task_family: "repository_change_and_verification",
      base_workflow_key: "add-demo-label-base",
      adapted_workflow_key: "add-demo-status-adapted",
      drafted_workflow_key: "add-demo-status-drafted",
      direct_request: %{objective: "Explain what an Elixir module is"},
      base_request: coding_base_request(),
      target_request: coding_target_request(),
      negative_request: %{
        objective: "Add DemoStatus.status/0 and verify its source",
        input: %{},
        input_paths: [42],
        metadata: %{path: "lib/demo_status.ex", expected: "def status"}
      },
      verify: &verify_coding/3
    }
  end

  defp coding_base_request do
    %{
      objective: "Add DemoLabel.label/0 and verify its source",
      input: %{},
      input_paths: ["lib/demo.ex"],
      metadata: %{path: "lib/demo_label.ex", expected: "def label"}
    }
  end

  defp coding_target_request do
    %{
      objective: "Add DemoStatus.status/0 and verify its source",
      input: %{},
      input_paths: ["lib/demo.ex"],
      metadata: %{path: "lib/demo_status.ex", expected: "def status"}
    }
  end

  defp coding_proposal(request) do
    path = request.metadata.path
    expected = request.metadata.expected
    module = if expected == "def label", do: "DemoLabel", else: "DemoStatus"
    function = if expected == "def label", do: "label", else: "status"

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
                  content: "defmodule #{module} do\n  def #{function}, do: :ok\nend\n"
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

  defp coding_agent_proposal(request) do
    path = request.metadata.path
    expected = request.metadata.expected

    %{
      id: "workflow:demo_status_agent",
      objective: request.objective,
      nodes: [
        %{
          id: "implement",
          kind: "agent",
          params: %{
            mode: "patch",
            task: "Create #{path} with DemoStatus.status/0 returning :ok."
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

  defp coding_adaptation_operations do
    target = coding_target_request()
    proposal = coding_proposal(target)
    implement = Enum.find(proposal.nodes, &(&1.id == "implement"))
    verify = Enum.find(proposal.nodes, &(&1.id == "verify"))

    [
      %{
        op: "set_argument",
        node_id: "implement",
        key: "operations",
        value: implement.params.operations
      },
      %{
        op: "set_argument",
        node_id: "verify",
        key: "checks",
        value: verify.params.checks
      },
      %{
        op: "set_acceptance",
        acceptance_id: "stop_1",
        check: %{
          id: "stop_1",
          kind: "declared_stop_condition",
          condition: "lib/demo_status.ex contains def status",
          required: true
        }
      }
    ]
  end

  defp verify_coding(execution, workspace, request) do
    path = Path.join(workspace.root, request.metadata.path)

    with true <- File.regular?(path),
         body <- File.read!(path),
         true <- String.contains?(body, request.metadata.expected),
         true <-
           Map.get(execution, :evaluation_arm) == :direct_agent or
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
            path: path,
            scorecards: Map.get(execution.context, :scorecards, []),
            episodes:
              Enum.map(execution.episodes, &%{id: &1.id, status: &1.status, outcome: &1.outcome})
          }}}
    end
  end
end
